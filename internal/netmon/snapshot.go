package netmon

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func WriteSnapshot(path string, snapshot Snapshot) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	w := bufio.NewWriter(tmp)
	metadataFormat := "M\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d"
	metadataArgs := []any{
		snapshot.Version, snapshot.UnixMilli, snapshot.IntervalMS, snapshot.Interface,
		snapshot.CapturedRXKBS, snapshot.CapturedTXKBS,
		snapshot.UnknownRXKBS, snapshot.UnknownTXKBS,
		snapshot.Packets, snapshot.Drops,
		snapshot.UnsupportedRXKBS, snapshot.UnsupportedTXKBS,
		snapshot.UnmatchedRXKBS, snapshot.UnmatchedTXKBS,
		snapshot.AmbiguousRXKBS, snapshot.AmbiguousTXKBS,
		snapshot.ExitedRXKBS, snapshot.ExitedTXKBS}
	if snapshot.Version >= 3 {
		metadataFormat += "\t%s\t%s\t%s\t%s"
		metadataArgs = append(metadataArgs, cleanTSV(snapshot.Source), cleanTSV(snapshot.Status), cleanTSV(snapshot.Scope), cleanTSV(snapshot.Reason))
	}
	metadataFormat += "\n"
	if _, err := fmt.Fprintf(w, metadataFormat, metadataArgs...); err != nil {
		_ = tmp.Close()
		return err
	}
	sort.Slice(snapshot.Processes, func(i, j int) bool { return snapshot.Processes[i].PID < snapshot.Processes[j].PID })
	for _, process := range snapshot.Processes {
		format := "P\t%d\t%d\t%d\t%d"
		args := []any{process.PID, process.StartTicks, process.RXKBS, process.TXKBS}
		if snapshot.Version >= 3 {
			format += "\t%s\t%s\t%s\t%s\t%s\t%s"
			args = append(args, cleanTSV(process.Scope), cleanTSV(process.Namespace), cleanTSV(process.Pod), cleanTSV(process.Container), cleanTSV(process.ContainerID), cleanTSV(process.Attribution))
		}
		if _, err := fmt.Fprintf(w, format+"\n", args...); err != nil {
			_ = tmp.Close()
			return err
		}
	}
	sort.Slice(snapshot.Entities, func(i, j int) bool { return snapshot.Entities[i].CgroupID < snapshot.Entities[j].CgroupID })
	for _, entity := range snapshot.Entities {
		if _, err := fmt.Fprintf(w, "C\t%d\t%s\t%s\t%s\t%s\t%d\t%d\t%s\n", entity.CgroupID,
			cleanTSV(entity.Namespace), cleanTSV(entity.Pod), cleanTSV(entity.Container), cleanTSV(entity.ContainerID), entity.RXKBS, entity.TXKBS, cleanTSV(entity.Attribution)); err != nil {
			_ = tmp.Close()
			return err
		}
	}
	if err := w.Flush(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func cleanTSV(value string) string {
	value = strings.NewReplacer("\t", " ", "\r", " ", "\n", " ").Replace(value)
	if value == "" {
		return "-"
	}
	return value
}
