package main

import (
	"crypto/sha1"
	"encoding/hex"
	"flag"
	"fmt"
	"regexp"
	"strings"
	"time"

	expect "github.com/google/goexpect"
)

// CarInfo struct to hold car information
type CarInfo struct {
	VIN       string
	LocalName string
	TTL       time.Time
	MAC       string
}

// Map to hold the car information with the local name as the key
var carMap = make(map[string]*CarInfo)

func main() {
	// Parse command line arguments
	vinList := flag.String("vinList", "", "List of VINs separated by space")
	ttlOffset := flag.Int("ttlOffset", 60, "TTL offset in seconds")
	flag.Parse()

	if *vinList == "" {
		fmt.Println("VIN list is required")
		return
	}

	// Populate the map
	populateMap(*vinList, *ttlOffset)

	// Generate regex patterns
	vinRegex := generateVinRegex(*vinList)
	localNameRegex := generateLocalNameRegex(*vinList)
	macRegex := generateMacRegex()

	// Interact with bluetoothctl
	err := interactWithBluetoothctl(vinRegex, localNameRegex, macRegex, *ttlOffset)
	if err != nil {
		fmt.Println("Error interacting with bluetoothctl:", err)
	}
}

// Populate the map with VINs and their respective information
func populateMap(vinList string, ttlOffset int) {
	vins := strings.Fields(vinList)

	for _, vin := range vins {
		localName := generateLocalName(vin)
		carMap[localName] = &CarInfo{
			VIN:       vin,
			LocalName: localName,
			TTL:       time.Now().Add(time.Duration(ttlOffset) * time.Second),
			MAC:       "",
		}
	}
}

// Generate SHA1 hash and convert to BLE Local Name
func generateLocalName(vin string) string {
	hash := sha1.New()
	hash.Write([]byte(vin))
	return hex.EncodeToString(hash.Sum(nil))
}

// Generate regex pattern for VINs
func generateVinRegex(vinList string) string {
	vins := strings.Fields(vinList)
	return fmt.Sprintf("(%s)", strings.Join(vins, "|"))
}

// Generate regex pattern for BLE Local Names
func generateLocalNameRegex(vinList string) string {
	vins := strings.Fields(vinList)
	var localNames []string
	for _, vin := range vins {
		localNames = append(localNames, generateLocalName(vin))
	}
	return fmt.Sprintf("(%s)", strings.Join(localNames, "|"))
}

// Generate regex pattern for MAC addresses
func generateMacRegex() string {
	var macs []string
	for _, car := range carMap {
		if car.MAC != "" {
			macs = append(macs, car.MAC)
		}
	}
	return fmt.Sprintf("(%s)", strings.Join(macs, "|"))
}

// Interact with bluetoothctl
func interactWithBluetoothctl(vinRegex, localNameRegex, macRegex string, ttlOffset int) error {
	// Start bluetoothctl
	e, _, err := expect.Spawn("bluetoothctl", -1)
	if err != nil {
		return err
	}
	defer e.Close()

	// Run 'devices' command
	_, _, err = e.Expect(regexp.MustCompile(`#`), time.Second*5)
	if err != nil {
		return err
	}
	e.Send("devices\n")

	// Process 'devices' output
	batch := []expect.Batcher{
		&expect.BExp{R: `Device (\S+) (.+)`},
	}
	_, err = e.ExpectBatch(batch, time.Second*10)
	if err != nil {
		return err
	}

	err = processDevicesOutput(e, localNameRegex)
	if err != nil {
		return err
	}

	// Run 'scan on' command
	e.Send("scan on\n")
	_, _, err = e.Expect(regexp.MustCompile(`#`), time.Second*5)
	if err != nil {
		return err
	}

	// Process 'scan on' output
	for {
		err = processScanOutput(e, localNameRegex, macRegex, ttlOffset)
		if err != nil {
			return err
		}
	}
}

// Process 'devices' command output
func processDevicesOutput(e *expect.GExpect, localNameRegex string) error {
	for {
		output, _, err := e.Expect(regexp.MustCompile(`Device (\S+) (.+)`), time.Second*10)
		if err != nil {
			return err
		}
		match := regexp.MustCompile(`Device (\S+) (.+)`).FindStringSubmatch(output)
		if match == nil {
			break
		}
		macAddr := match[1]
		localName := match[2]
		if _, exists := carMap[localName]; exists {
			carMap[localName].MAC = macAddr
		}
	}
	return nil
}

// Process 'scan on' command output
func processScanOutput(e *expect.GExpect, localNameRegex, macRegex string, ttlOffset int) error {
	output, _, err := e.Expect(regexp.MustCompile(`(New|Del|CHG) (\S+) (.+)`), time.Second*10)
	if err != nil {
		return err
	}
	match := regexp.MustCompile(`(New|Del|CHG) (\S+) (.+)`).FindStringSubmatch(output)
	if match == nil {
		return nil
	}
	action := match[1]
	macAddr := match[2]
	info := match[3]

	switch action {
	case "New", "Del":
		localName := info
		if _, exists := carMap[localName]; exists {
			carMap[localName].MAC = macAddr
			carMap[localName].TTL = time.Now().Add(time.Duration(ttlOffset) * time.Second)
		}
	case "CHG":
		for _, car := range carMap {
			if car.MAC == macAddr {
				car.TTL = time.Now().Add(time.Duration(ttlOffset) * time.Second)
				break
			}
		}
	}
	return nil
}
