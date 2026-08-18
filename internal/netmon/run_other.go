//go:build !linux

package netmon

import (
	"context"
	"errors"
	"time"
)

type Config struct {
	Interface     string
	Interval      time.Duration
	Output        string
	Once          bool
	ProcRoot      string
	CgroupRoot    string
	ContainerLogs string
	PodLogs       string
}

func Run(context.Context, Config) error {
	return errors.New("AF_PACKET capture is only supported on Linux")
}
