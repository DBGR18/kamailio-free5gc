// The AF shim that lets the P-CSCF reserve QoS for a call.
//
// In IMS this job belongs to the P-CSCF itself: it reads the negotiated SDP
// and asks the policy function to authorise the media flow. Kamailio can do
// that over Rx, but free5gc has no Rx -- its PCF offers the 5G equivalent,
// Npcf_PolicyAuthorization, over HTTP/2 cleartext. So the P-CSCF calls this
// service over ordinary HTTP and this service speaks h2c to the PCF.
//
// What one call produces, end to end:
//
//	P-CSCF  --POST /call-->  AF  --POST /app-sessions-->  PCF
//	                                  PCF builds a PCC rule + QoS data
//	                                  and notifies the SMF
//	                             SMF applies them and modifies the PFCP
//	                                  session, which installs a QER at the UPF
//
// The last step is the one worth verifying. free5gc implements the QoS spec
// surface but enforces none of it -- no rate limiting, no guaranteed bitrate
// -- so the only honest check is that the rule reached the UPF, never a
// throughput measurement.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

// ---------------------------------------------------------------- N5 models
//
// Declared here rather than imported from github.com/free5gc/openapi so that
// this container does not have to track free5gc's module version. The field
// names and the wire types are copied from that package and must stay in step
// with it; the PCF ignores anything it does not recognise, so a renamed field
// fails silently rather than loudly.

type mediaSubComponent struct {
	FNum      int32    `json:"fNum"`
	FDescs    []string `json:"fDescs,omitempty"`
	FStatus   string   `json:"fStatus,omitempty"`
	FlowUsage string   `json:"flowUsage,omitempty"`
	MarBwUl   string   `json:"marBwUl,omitempty"`
	MarBwDl   string   `json:"marBwDl,omitempty"`
}

type mediaComponent struct {
	MedCompN    int32                        `json:"medCompN"`
	MedType     string                       `json:"medType,omitempty"`
	FStatus     string                       `json:"fStatus,omitempty"`
	MarBwUl     string                       `json:"marBwUl,omitempty"`
	MarBwDl     string                       `json:"marBwDl,omitempty"`
	Codecs      []string                     `json:"codecs,omitempty"`
	MedSubComps map[string]mediaSubComponent `json:"medSubComps,omitempty"`
}

type appSessionContextReqData struct {
	AfAppId  string `json:"afAppId,omitempty"`
	AspId    string `json:"aspId,omitempty"`
	Dnn      string `json:"dnn,omitempty"`
	NotifUri string `json:"notifUri"`
	Supi     string `json:"supi,omitempty"`
	UeIpv4   string `json:"ueIpv4,omitempty"`
	// Mandatory, and rejected at the API layer before any of the interesting
	// code runs if it is absent. It is a hex bitmask of optional features;
	// "0" asks for none, which is what this AF needs -- bit 1 would be
	// traffic-routing influence.
	SuppFeat      string                    `json:"suppFeat"`
	MedComponents map[string]mediaComponent `json:"medComponents,omitempty"`
}

type appSessionContext struct {
	AscReqData *appSessionContextReqData `json:"ascReqData"`
}

// ------------------------------------------------------- what kamailio sends

type callRequest struct {
	CallID   string `json:"callId"`
	Supi     string `json:"supi"`
	Dnn      string `json:"dnn"`
	UeAddr   string `json:"ueAddr"`
	UePort   int    `json:"uePort"`
	PeerAddr string `json:"peerAddr"`
	PeerPort int    `json:"peerPort"`
	BwUl     string `json:"bwUl"`
	BwDl     string `json:"bwDl"`

	// The P-CSCF sends the negotiated SDP instead of the four fields above,
	// because picking the addresses apart is text work that the kamailio
	// config is a bad place for: its re.subst is a POSIX substitution whose
	// "." stops at a newline, so it cannot reach across SDP lines, and on a
	// failed match it returns the subject unchanged -- which looks like a
	// successful extraction of the whole body.
	//
	// Both are base64 so that a body full of CRLFs survives being a JSON
	// string without any escaping to get wrong.
	Dir       string `json:"dir"`
	OfferSdp  string `json:"offerSdp"`
	AnswerSdp string `json:"answerSdp"`
}

// sdpEndpoint is the address and port one side of an offer/answer published.
type sdpEndpoint struct {
	Addr string
	Port int
}

// parseSdp pulls the connection address and the audio port out of an SDP.
// Only what this AF needs: one audio stream, IPv4.
func parseSdp(b64 string) (sdpEndpoint, error) {
	var ep sdpEndpoint
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return ep, fmt.Errorf("sdp is not valid base64: %w", err)
	}
	for _, line := range strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n") {
		f := strings.Fields(line)
		switch {
		case strings.HasPrefix(line, "c=") && len(f) >= 3:
			// c=IN IP4 10.62.0.1
			ep.Addr = f[2]
		case strings.HasPrefix(line, "m=audio") && len(f) >= 2:
			// m=audio 6000 RTP/AVP 8
			if port, cErr := strconv.Atoi(f[1]); cErr == nil {
				ep.Port = port
			}
		}
	}
	if ep.Addr == "" || ep.Port == 0 {
		return ep, fmt.Errorf("no IPv4 audio stream in the sdp")
	}
	return ep, nil
}

type server struct {
	pcf          string
	nrf          string
	nfInstanceID string
	notifUri     string
	client       *http.Client

	mu       sync.Mutex
	sessions map[string]string // Call-ID -> app session resource URI

	tokenMu  sync.Mutex
	token    string
	tokenExp time.Time
	oauthOff bool
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	s := &server{
		pcf: strings.TrimSuffix(env("PCF_URI", "http://pcf:8000"), "/"),
		nrf: strings.TrimSuffix(env("NRF_URI", "http://nrf.free5gc.org:8000"), "/"),
		// The identity free5gc's certificate generator already issues for an
		// AF. cert/af_<this id>.pem carries a URI SAN of urn:uuid:<this id>,
		// and the NRF checks the two against each other when it issues a
		// token -- so this value is not free to choose.
		nfInstanceID: env("AF_NF_INSTANCE_ID", "b628a2ad-7821-4869-b891-ff20548bde83"),
		notifUri:     env("AF_NOTIF_URI", "http://af:8090/notify"),
		sessions:     make(map[string]string),
		// h2c: HTTP/2 with prior knowledge, no TLS. free5gc's SBI speaks
		// nothing else, and an ordinary net/http client would send an
		// HTTP/1.1 request that the PCF simply drops.
		client: &http.Client{
			Timeout: 10 * time.Second,
			Transport: &http2.Transport{
				AllowHTTP: true,
				DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
					return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, addr)
				},
			},
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/call", s.handleCall)
	mux.HandleFunc("/call/delete", s.handleCallDelete)
	mux.HandleFunc("/notify", s.handleNotify)
	mux.HandleFunc("/sessions", s.handleSessions)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	go s.register()

	addr := env("AF_LISTEN", ":8090")
	log.Printf("[af] listening on %s, PCF at %s, NRF at %s", addr, s.pcf, s.nrf)
	// h2c wrapper so the same listener serves kamailio (HTTP/1.1) and the
	// PCF's notifications (HTTP/2 prior knowledge).
	srv := &http.Server{
		Addr:              addr,
		Handler:           h2c.NewHandler(mux, &http2.Server{}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

// buildContext turns one negotiated audio stream into an app session context.
//
// The two flow descriptions are written from the network's point of view, and
// their direction is carried by the verb rather than by the addresses: the PCF
// reads "permit out" as downlink and "permit in" as uplink, and rewrites the
// latter before passing it on. Note that "permit inout" must not be used --
// the PCF tests for the "permit in" prefix first, so an inout rule is silently
// classified as uplink only.
func (s *server) buildContext(req *callRequest) *appSessionContext {
	flow := func(verb string) string {
		return fmt.Sprintf("%s 17 from %s %d to %s %d",
			verb, req.PeerAddr, req.PeerPort, req.UeAddr, req.UePort)
	}

	sub := mediaSubComponent{
		FNum:      1,
		FStatus:   "ENABLED",
		FlowUsage: "NO_INFO",
		FDescs:    []string{flow("permit out"), flow("permit in")},
		MarBwUl:   req.BwUl,
		MarBwDl:   req.BwDl,
	}

	comp := mediaComponent{
		MedCompN: 1,
		// AUDIO is what makes this worth doing: the PCF maps it to 5QI 1,
		// conversational voice, which is the only branch that reads the
		// requested bit rates at all. Any other media type lands on 5QI 9
		// and the bandwidth fields are ignored.
		MedType:     "AUDIO",
		FStatus:     "ENABLED",
		MarBwUl:     req.BwUl,
		MarBwDl:     req.BwDl,
		Codecs:      []string{"PCMA"},
		MedSubComps: map[string]mediaSubComponent{"1": sub},
	}

	return &appSessionContext{
		AscReqData: &appSessionContextReqData{
			AfAppId:  "IMS-voice",
			Dnn:      req.Dnn,
			NotifUri: s.notifUri,
			SuppFeat: "0",
			// Supi matters more than it looks. Without it the PCF falls back
			// to searching every UE it knows for one holding this IP, and
			// that loop overwrites its result on every iteration instead of
			// stopping at the match -- so with more than one UE attached the
			// binding succeeds only when sync.Map.Range happens to visit the
			// right UE last. Supplying Supi takes the direct path instead.
			Supi:          req.Supi,
			UeIpv4:        req.UeAddr,
			MedComponents: map[string]mediaComponent{"1": comp},
		},
	}
}

func (s *server) handleCall(w http.ResponseWriter, r *http.Request) {
	var req callRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.OfferSdp != "" && req.AnswerSdp != "" {
		offer, oErr := parseSdp(req.OfferSdp)
		answer, aErr := parseSdp(req.AnswerSdp)
		if oErr != nil || aErr != nil {
			http.Error(w, fmt.Sprintf("offer: %v; answer: %v", oErr, aErr), http.StatusBadRequest)
			return
		}
		// Which half of the offer/answer belongs to the UE this leg serves
		// is the one thing the AF cannot work out for itself.
		near, far := offer, answer
		if req.Dir == "term" {
			near, far = answer, offer
		}
		req.UePort = near.Port
		req.PeerAddr, req.PeerPort = far.Addr, far.Port
		// UeAddr stays whatever the P-CSCF said: that is the address of the
		// PDU session, and the PCF binds the app session on it. The SDP is
		// the UE's own claim about itself and is not authority for that.
		if req.UeAddr == "" {
			req.UeAddr = near.Addr
		}
	}
	if req.CallID == "" || req.UeAddr == "" || req.PeerAddr == "" {
		http.Error(w, "callId, ueAddr and peerAddr are required", http.StatusBadRequest)
		return
	}
	if req.Dnn == "" {
		req.Dnn = env("AF_DNN", "ims")
	}
	if req.BwUl == "" {
		req.BwUl = env("AF_BW_UL", "64 Kbps")
	}
	if req.BwDl == "" {
		req.BwDl = env("AF_BW_DL", "64 Kbps")
	}

	body, err := json.Marshal(s.buildContext(&req))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	url := s.pcf + "/npcf-policyauthorization/v1/app-sessions"
	log.Printf("[af] call %s: POST %s", req.CallID, url)
	// The whole body, because the PCF accepts a request whose media
	// components failed to parse: it answers 201 and simply never notifies
	// the SMF, so a silent mistake here looks like success everywhere else.
	log.Printf("[af] call %s: %s", req.CallID, body)

	resp, err := s.post(url, body)
	if err != nil {
		log.Printf("[af] call %s: PCF unreachable: %v", req.CallID, err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	payload, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusCreated {
		log.Printf("[af] call %s: PCF answered %d: %s", req.CallID, resp.StatusCode, payload)
		http.Error(w, string(payload), http.StatusBadGateway)
		return
	}

	// The resource URI comes back in Location. It is what a later delete
	// needs, and it is the only handle the PCF gives us.
	loc := resp.Header.Get("Location")
	s.mu.Lock()
	s.sessions[req.CallID] = loc
	s.mu.Unlock()
	log.Printf("[af] call %s: app session created at %s", req.CallID, loc)

	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, loc)
}

func (s *server) handleCallDelete(w http.ResponseWriter, r *http.Request) {
	var req callRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request body: "+err.Error(), http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	loc, ok := s.sessions[req.CallID]
	delete(s.sessions, req.CallID)
	s.mu.Unlock()

	if !ok {
		// Not an error worth failing the BYE over: a call that never got a
		// reservation still has to hang up cleanly.
		log.Printf("[af] delete %s: no app session recorded", req.CallID)
		w.WriteHeader(http.StatusOK)
		return
	}

	url := s.resolve(loc) + "/delete"
	resp, err := s.post(url, []byte("{}"))
	if err != nil {
		log.Printf("[af] delete %s: PCF unreachable: %v", req.CallID, err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	payload, _ := io.ReadAll(resp.Body)
	log.Printf("[af] delete %s: PCF answered %d %s", req.CallID, resp.StatusCode, strings.TrimSpace(string(payload)))
	w.WriteHeader(http.StatusOK)
}

// resolve turns whatever the PCF put in Location into something dialable. It
// normally returns an absolute URI, but a relative one is legal.
func (s *server) resolve(loc string) string {
	if strings.HasPrefix(loc, "http://") || strings.HasPrefix(loc, "https://") {
		return loc
	}
	return s.pcf + "/" + strings.TrimPrefix(loc, "/")
}

func (s *server) post(url string, body []byte) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if token, tErr := s.accessToken(); tErr != nil {
		return nil, tErr
	} else if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	return s.client.Do(req)
}

// handleNotify accepts the PCF's event notifications. Nothing acts on them
// yet; answering 204 keeps the PCF from retrying.
func (s *server) handleNotify(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	log.Printf("[af] notification from the PCF: %s", strings.TrimSpace(string(body)))
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleSessions(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(s.sessions); err != nil {
		log.Printf("[af] encoding sessions: %v", err)
	}
}

// ------------------------------------------------------------ NF identity
//
// The PCF rejects an unauthenticated request outright, because this
// deployment's NRF runs with oauth enabled and every NF then verifies the
// bearer token on each SBI call. Getting one has two prerequisites, and the
// NRF checks both:
//
//   - this AF is registered in the NRF, so its profile can be looked up by
//     nfInstanceId and its nfType compared against the request;
//   - a certificate exists at cert/af_<nfInstanceId>.pem whose URI SAN names
//     the same instance id. The NRF reads that file from its own filesystem;
//     nothing here presents it, so the AF needs no private key of its own.
//
// The token itself is only checked for signature and scope by the producer --
// not for audience -- so targetNfInstanceId can be left out.

type nfProfile struct {
	NfInstanceId  string   `json:"nfInstanceId"`
	NfType        string   `json:"nfType"`
	NfStatus      string   `json:"nfStatus"`
	Ipv4Addresses []string `json:"ipv4Addresses,omitempty"`
}

type accessTokenRsp struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int32  `json:"expires_in"`
	Scope       string `json:"scope"`
}

// register puts this AF into the NRF and keeps retrying: the AF container can
// easily win the race against the NRF's own startup.
func (s *server) register() {
	profile := nfProfile{
		NfInstanceId: s.nfInstanceID,
		NfType:       "AF",
		NfStatus:     "REGISTERED",
	}
	if addr := env("AF_CORENET_IP", ""); addr != "" {
		profile.Ipv4Addresses = []string{addr}
	}
	body, err := json.Marshal(profile)
	if err != nil {
		log.Printf("[af] cannot encode the NF profile: %v", err)
		return
	}
	url := fmt.Sprintf("%s/nnrf-nfm/v1/nf-instances/%s", s.nrf, s.nfInstanceID)

	for attempt := 1; ; attempt++ {
		req, reqErr := http.NewRequest(http.MethodPut, url, bytes.NewReader(body))
		if reqErr != nil {
			log.Printf("[af] cannot build the registration request: %v", reqErr)
			return
		}
		req.Header.Set("Content-Type", "application/json")

		resp, doErr := s.client.Do(req)
		if doErr == nil {
			payload, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == http.StatusCreated || resp.StatusCode == http.StatusOK {
				log.Printf("[af] registered with the NRF as AF %s", s.nfInstanceID)
				return
			}
			log.Printf("[af] NRF registration attempt %d: %d %s",
				attempt, resp.StatusCode, strings.TrimSpace(string(payload)))
		} else {
			log.Printf("[af] NRF registration attempt %d: %v", attempt, doErr)
		}
		if attempt >= 30 {
			log.Printf("[af] giving up on NRF registration; PCF calls will be rejected")
			return
		}
		time.Sleep(2 * time.Second)
	}
}

// accessToken returns a cached token, fetching a new one shortly before the
// old one expires so a call never fails on a boundary.
func (s *server) accessToken() (string, error) {
	s.tokenMu.Lock()
	defer s.tokenMu.Unlock()

	if s.oauthOff {
		return "", nil
	}
	if s.token != "" && time.Now().Before(s.tokenExp) {
		return s.token, nil
	}

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("nfInstanceId", s.nfInstanceID)
	form.Set("nfType", "AF")
	form.Set("targetNfType", "PCF")
	form.Set("scope", "npcf-policyauthorization")

	// The NRF parses this form field by field and rejects the whole request
	// on any key it does not recognise, matching against the yaml tags of its
	// own request model -- so every name above has to be exact.
	req, err := http.NewRequest(http.MethodPost, s.nrf+"/oauth2/token",
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Content-Length", strconv.Itoa(len(form.Encode())))

	resp, err := s.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("asking the NRF for a token: %w", err)
	}
	defer resp.Body.Close()
	payload, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		// A deployment can run with oauth switched off at the NRF, and then
		// the token endpoint refuses everyone. That is not an error here:
		// the producers are not checking tokens either, so the right move is
		// to carry on without one. Any other refusal is a real failure.
		if strings.Contains(string(payload), "OAuth2 not enable") {
			log.Printf("[af] the NRF has OAuth disabled; calling the PCF without a token")
			s.oauthOff = true
			return "", nil
		}
		return "", fmt.Errorf("NRF refused a token: %d %s", resp.StatusCode, strings.TrimSpace(string(payload)))
	}

	var rsp accessTokenRsp
	if err := json.Unmarshal(payload, &rsp); err != nil {
		return "", fmt.Errorf("decoding the token: %w", err)
	}
	s.token = rsp.AccessToken
	s.tokenExp = time.Now().Add(time.Duration(rsp.ExpiresIn) * time.Second).Add(-60 * time.Second)
	log.Printf("[af] got an access token from the NRF, scope %q, good for %ds", rsp.Scope, rsp.ExpiresIn)
	return s.token, nil
}
