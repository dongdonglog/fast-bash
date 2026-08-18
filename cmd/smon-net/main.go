package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dongdonglog/fast-bash/internal/netmon"
)

var version = "dev"

func main() {
	iface := flag.String("interface", "", "network interface to capture")
	interval := flag.Duration("interval", time.Second, "snapshot interval")
	output := flag.String("output", "", "snapshot output path")
	once := flag.Bool("once", false, "write one snapshot and exit")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("smon-net %s\n", version)
		return
	}
	if *iface == "" || *output == "" {
		fmt.Fprintln(os.Stderr, "--interface and --output are required")
		os.Exit(2)
	}
	if *interval < 100*time.Millisecond || *interval > time.Minute {
		fmt.Fprintln(os.Stderr, "--interval must be between 100ms and 1m")
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err := netmon.Run(ctx, netmon.Config{
		Interface: *iface,
		Interval:  *interval,
		Output:    *output,
		Once:      *once,
		ProcRoot:  "/proc",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "smon-net: %v\n", err)
		os.Exit(1)
	}
}
