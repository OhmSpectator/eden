package utils

import (
	"bytes"
	"text/template"

	"github.com/lf-edge/eden/pkg/defaults"
)

// QemuSettings struct for pass into template
type QemuSettings struct {
	DTBDrive   string
	Firmware   []string
	Disks      []string
	USBDisks   []string // USB storage disk images to attach to the VM
	MemoryMB   int
	CPUs       int
	USBSerials int
	USBTablets int
}

// GenerateQemuConfig provides string representation of Qemu config
// for QemuSettings object
func (settings QemuSettings) GenerateQemuConfig() ([]byte, error) {
	funcMap := template.FuncMap{
		"add": func(a, b int) int { return a + b },
	}
	t := template.New("t").Funcs(funcMap)
	t, err := t.Parse(defaults.DefaultQemuTemplate)
	if err != nil {
		return nil, err
	}
	buf := new(bytes.Buffer)
	err = t.Execute(buf, settings)
	if err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
