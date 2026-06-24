// Copyright 2026 venti1112, 3788365896@qq.com
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Package main builds frpc as a c-shared library (libfrpc.so).
//
// It is intended to be dlopen'd by a tiny native loader and run as an
// isolated sidecar process (e.g. on Android, where execve from the app's
// writable data directory is forbidden but dlopen of a .so from it is
// allowed). Because the engine lives in the data directory rather than in
// the APK's read-only lib directory, it can be updated independently of the
// host application.
//
// Exported C ABI:
//
//	int  RunFrpc(const char *configPath);  // blocks until the service stops
//	void StopFrpc(void);                    // gracefully stops a running service
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/fatedier/frp/client"
	"github.com/fatedier/frp/pkg/config"
	"github.com/fatedier/frp/pkg/config/source"
	"github.com/fatedier/frp/pkg/config/v1/validation"
	"github.com/fatedier/frp/pkg/policy/featuregate"
	"github.com/fatedier/frp/pkg/policy/security"
	"github.com/fatedier/frp/pkg/util/log"
)

var (
	mu      sync.Mutex
	current *client.Service
)

// RunFrpc loads the client configuration at configPath and runs frpc. It
// blocks until the service stops, so the caller must invoke it on a dedicated
// thread. Returns 0 on a clean shutdown and 1 if startup or runtime failed.
//
//export RunFrpc
func RunFrpc(configPath *C.char) C.int {
	if err := runFrpc(C.GoString(configPath)); err != nil {
		log.Errorf("frpc service exited with error: %v", err)
		return 1
	}
	return 0
}

// StopFrpc gracefully stops the service started by RunFrpc. It is safe to call
// when nothing is running. Typically wired to SIGTERM by the native loader.
//
//export StopFrpc
func StopFrpc() {
	mu.Lock()
	svr := current
	current = nil
	mu.Unlock()
	if svr != nil {
		svr.GracefulClose(500 * time.Millisecond)
	}
}

// runFrpc mirrors cmd/frpc/sub/root.go's runClient path: load the config,
// apply feature gates, build the source aggregator, validate, then start the
// service. Strict parsing is disabled so newer/unknown fields don't hard-fail
// a remotely delivered config.
func runFrpc(cfgFilePath string) error {
	result, err := config.LoadClientConfigResult(cfgFilePath, false)
	if err != nil {
		return err
	}
	if len(result.Common.FeatureGates) > 0 {
		if err := featuregate.SetFromMap(result.Common.FeatureGates); err != nil {
			return err
		}
	}

	configSource := source.NewConfigSource()
	if err := configSource.ReplaceAll(result.Proxies, result.Visitors); err != nil {
		return fmt.Errorf("set config source: %w", err)
	}
	aggregator := source.NewAggregator(configSource)

	proxyCfgs, visitorCfgs, err := aggregator.Load()
	if err != nil {
		return fmt.Errorf("load config from sources: %w", err)
	}
	proxyCfgs, visitorCfgs = config.FilterClientConfigurers(result.Common, proxyCfgs, visitorCfgs)
	proxyCfgs = config.CompleteProxyConfigurers(proxyCfgs)
	visitorCfgs = config.CompleteVisitorConfigurers(visitorCfgs)

	unsafeFeatures := security.NewUnsafeFeatures(nil)
	warning, err := validation.ValidateAllClientConfig(result.Common, proxyCfgs, visitorCfgs, unsafeFeatures)
	if warning != nil {
		log.Warnf("validation warning: %v", warning)
	}
	if err != nil {
		return err
	}

	log.InitLogger(result.Common.Log.To, result.Common.Log.Level,
		int(result.Common.Log.MaxDays), result.Common.Log.DisablePrintColor)

	svr, err := client.NewService(client.ServiceOptions{
		Common:                 result.Common,
		ConfigSourceAggregator: aggregator,
		UnsafeFeatures:         unsafeFeatures,
		ConfigFilePath:         cfgFilePath,
	})
	if err != nil {
		return err
	}

	mu.Lock()
	current = svr
	mu.Unlock()

	// Running as a child process: respond to SIGINT/SIGTERM with a graceful
	// shutdown. The Kotlin side stops the tunnel via Process.destroy(), which
	// sends SIGTERM. The Go runtime takes over signal handling once this
	// library is dlopen'd, so signal.Notify here routes it to our channel
	// instead of the default terminate-immediately behavior.
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
		<-ch
		svr.GracefulClose(500 * time.Millisecond)
	}()

	return svr.Run(context.Background())
}

// main is required for a c-shared build but is never executed when the
// resulting library is loaded via dlopen.
func main() {}
