//go:build ios || darwin

package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"sync"
	"sync/atomic"

	"github.com/xtls/libxray/xray"
)

var procMap sync.Map
var instMu sync.Mutex
var tunnelSeq atomic.Int64
var tunnelSession sync.Map
var tunnelLastError atomic.Value

//export XrayTunnelMemoryStats
func XrayTunnelMemoryStats() *C.char {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	memoryLimit, gcPercent := tunnelGovernorSnapshot()
	payload := map[string]interface{}{
		"heapInUse":    stats.HeapInuse,
		"heapIdle":     stats.HeapIdle,
		"heapReleased": stats.HeapReleased,
		"sys":          stats.Sys,
		"numGC":        stats.NumGC,
		"goroutines":   runtime.NumGoroutine(),
		// The soft limit in effect (math.MaxInt64 when disabled) and the GC
		// percent the tunnel session applied (-1 when none is active).
		"memoryLimit": memoryLimit,
		"gcPercent":   gcPercent,
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return C.CString("{}")
	}
	return C.CString(string(encoded))
}

func setTunnelLastError(msg string) {
	tunnelLastError.Store(msg)
}

func getTunnelLastError() string {
	if value := tunnelLastError.Load(); value != nil {
		if text, ok := value.(string); ok {
			return text
		}
	}
	return ""
}

func injectSockoptInterface(cfgData []byte, iface string) []byte {
	if iface == "" {
		return cfgData
	}
	var doc map[string]interface{}
	if err := json.Unmarshal(cfgData, &doc); err != nil {
		return cfgData
	}

	outbounds, ok := doc["outbounds"].([]interface{})
	if !ok {
		return cfgData
	}
	for i, ob := range outbounds {
		obMap, ok := ob.(map[string]interface{})
		if !ok {
			continue
		}
		streamSettings, ok := obMap["streamSettings"].(map[string]interface{})
		if !ok {
			streamSettings = make(map[string]interface{})
			obMap["streamSettings"] = streamSettings
		}
		sockopt, ok := streamSettings["sockopt"].(map[string]interface{})
		if !ok {
			sockopt = make(map[string]interface{})
			streamSettings["sockopt"] = sockopt
		}
		sockopt["interface"] = iface
		outbounds[i] = obMap
	}
	if modifiedBytes, err := json.Marshal(doc); err == nil {
		return modifiedBytes
	}
	return cfgData
}

func startXrayInternal(cfgData []byte) error {
	if xray.GetXrayState() {
		return errors.New("already running")
	}
	return xray.RunXrayFromJSON(string(cfgData))
}

func stopXrayInternal() error {
	if !xray.GetXrayState() {
		return errors.New("not running")
	}
	return xray.StopXray()
}

func clearNodeRegistry() {
	procMap.Range(func(key, value any) bool {
		procMap.Delete(key)
		return true
	})
}

//export WriteConfigFiles
func WriteConfigFiles(xrayPathC, xrayContentC, servicePathC, serviceContentC, vpnPathC, vpnContentC, passwordC *C.char) *C.char {
	xrayPath := C.GoString(xrayPathC)
	xrayContent := C.GoString(xrayContentC)
	servicePath := C.GoString(servicePathC)
	serviceContent := C.GoString(serviceContentC)
	vpnPath := C.GoString(vpnPathC)
	vpnContent := C.GoString(vpnContentC)
	if err := os.WriteFile(xrayPath, []byte(xrayContent), 0o644); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.WriteFile(servicePath, []byte(serviceContent), 0o644); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.WriteFile(vpnPath, []byte(vpnContent), 0o644); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("success")
}

//export StartNodeService
func StartNodeService(name *C.char) *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	node := C.GoString(name)
	if _, ok := procMap.Load(node); ok && xray.GetXrayState() {
		return C.CString("success")
	}
	if xray.GetXrayState() {
		if err := stopXrayInternal(); err != nil {
			return C.CString("error:already running: " + err.Error())
		}
		clearNodeRegistry()
	}

	configPath := filepath.Join(os.TempDir(), node+".json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := startXrayInternal(data); err != nil {
		return C.CString("error:" + err.Error())
	}
	procMap.Store(node, true)
	return C.CString("success")
}

//export StopNodeService
func StopNodeService(name *C.char) *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	node := C.GoString(name)
	procMap.Delete(node)
	if xray.GetXrayState() {
		if err := stopXrayInternal(); err != nil {
			return C.CString("error:" + err.Error())
		}
	}
	clearNodeRegistry()
	return C.CString("success")
}

//export CheckNodeStatus
func CheckNodeStatus(name *C.char) C.int {
	node := C.GoString(name)
	if _, ok := procMap.Load(node); ok && xray.GetXrayState() {
		return 1
	}
	return 0
}

//export StartXray
func StartXray(configC *C.char) *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	if xray.GetXrayState() {
		if err := stopXrayInternal(); err != nil {
			return C.CString("error:already running: " + err.Error())
		}
		clearNodeRegistry()
	}
	cfgData := []byte(C.GoString(configC))
	if err := startXrayInternal(cfgData); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("success")
}

//export StopXray
func StopXray() *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	if !xray.GetXrayState() {
		clearNodeRegistry()
		return C.CString("success")
	}
	if err := stopXrayInternal(); err != nil {
		return C.CString("error:" + err.Error())
	}
	clearNodeRegistry()
	return C.CString("success")
}

//export StartXrayTunnelWithFd
func StartXrayTunnelWithFd(configC *C.char, fd C.int, interfaceC *C.char) C.longlong {
	instMu.Lock()
	defer instMu.Unlock()
	return startXrayTunnelWithFd(configC, fd, interfaceC, tunnelGovernorSettingsFromEnv())
}

// StartXrayTunnelWithFdTuned is StartXrayTunnelWithFd with explicit runtime
// tuning. A negative value selects the default; a memory limit of 0 removes
// the soft limit. Settings apply to this session only and are restored when
// it stops or fails to start.
//
//export StartXrayTunnelWithFdTuned
func StartXrayTunnelWithFdTuned(configC *C.char, fd C.int, interfaceC *C.char, memoryLimitMB C.longlong, gcPercent C.int) C.longlong {
	instMu.Lock()
	defer instMu.Unlock()
	settings, err := resolveTunnelGovernorSettings(int64(memoryLimitMB), int64(gcPercent))
	if err != nil {
		setTunnelLastError("invalid tunnel tuning: " + err.Error())
		return C.longlong(-1)
	}
	return startXrayTunnelWithFd(configC, fd, interfaceC, settings)
}

// startXrayTunnelWithFd must be called with instMu held, so validation, the
// governor and the start form one critical section.
func startXrayTunnelWithFd(configC *C.char, fd C.int, interfaceC *C.char, settings tunnelGovernorSettings) C.longlong {
	if xray.GetXrayState() {
		setTunnelLastError("xray already running")
		return C.longlong(-1)
	}

	if int(fd) < 0 {
		setTunnelLastError("invalid tun fd")
		return C.longlong(-1)
	}

	// Set Xray TUN file descriptor environment variable natively supported by libxray's Darwin TUN implementation
	os.Setenv("xray.tun.fd", strconv.Itoa(int(fd)))

	cfgData := []byte(C.GoString(configC))
	if interfaceC != nil {
		ifaceStr := C.GoString(interfaceC)
		if ifaceStr != "" {
			cfgData = injectSockoptInterface(cfgData, ifaceStr)
		}
	}

	if err := startTunnelMemoryGovernor(settings); err != nil {
		setTunnelLastError(err.Error())
		return C.longlong(-1)
	}

	if err := startXrayInternal(cfgData); err != nil {
		stopTunnelMemoryGovernor()
		setTunnelLastError(err.Error())
		return C.longlong(-1)
	}

	setTunnelLastError("")
	handle := tunnelSeq.Add(1)
	tunnelSession.Store(handle, true)
	return C.longlong(handle)
}

//export GetLastXrayTunnelError
func GetLastXrayTunnelError() *C.char {
	return C.CString(getTunnelLastError())
}

//export StopXrayTunnel
func StopXrayTunnel(handle C.longlong) *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	id := int64(handle)
	if id <= 0 {
		return C.CString("error:invalid handle")
	}
	if _, ok := tunnelSession.Load(id); !ok {
		return C.CString("error:session not found")
	}
	tunnelSession.Delete(id)

	if xray.GetXrayState() {
		if err := stopXrayInternal(); err != nil {
			return C.CString("error:" + err.Error())
		}
	}
	clearNodeRegistry()
	stopTunnelMemoryGovernor()
	// The session's buffers are unreachable now; hand them back before the
	// extension idles, rather than waiting for the next scavenge tick.
	debug.FreeOSMemory()
	return C.CString("success")
}

//export FreeXrayTunnel
func FreeXrayTunnel(handle C.longlong) *C.char {
	id := int64(handle)
	if id <= 0 {
		return C.CString("error:invalid handle")
	}
	tunnelSession.Delete(id)
	return C.CString("success")
}

//export CreateWindowsService
func CreateWindowsService(name, execPath, configPath *C.char) *C.char {
	return C.CString("error:not supported")
}

//export PerformAction
func PerformAction(action, password *C.char) *C.char {
	act := C.GoString(action)
	if act == "isXrayDownloading" {
		return C.CString("0")
	}
	return C.CString("error:unsupported")
}

//export IsXrayDownloading
func IsXrayDownloading() C.int { return 0 }

