# D65 Probe, OpenDisplay build

OpenDisplay's white-point calibration needs the iPhone probe from [Tinnci/d65](https://github.com/Tinnci/d65)
(MIT) with `raw-channels.patch` applied. The patch makes the probe:

- send the light sensor's raw channels 0–3, its colour-space flag, illuminance and calibration blob in
  each sample's `channels` (field numbers from Apple's open-source `IOHIDEventFieldDefs.h`,
  IOHIDFamily-1787). OpenDisplay corrects the phone with the raw channels, because the firmware's own
  XYZ is neither accurate nor linear;
- smooth its stillness gate over about 0.2 s, so a hand holding the phone to an upright monitor
  doesn't keep resetting placement.

The probe is sideload-only (it reads the sensor through private IOHID). To build and install it:

```bash
git clone https://github.com/Tinnci/d65.git && cd d65 && git checkout 0c338d8
git apply /path/to/OpenDisplay/Tools/d65-probe/raw-channels.patch
```

Then, in `project.yml`, set the D65Probe target's `PRODUCT_BUNDLE_IDENTIFIER` to one your Apple
developer team can sign, regenerate the project, and build the `D65Probe` scheme for your iPhone:

```bash
xcodegen generate
xcodebuild -project D65.xcodeproj -scheme D65Probe -configuration Release \
  -destination 'id=<iPhone UDID>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<team ID> build
xcrun devicectl device install app --device <iPhone UDID> <DerivedData>/Build/Products/Release-iphoneos/D65Probe.app
```

Once the probe is on the phone, open the White point card on an external display's page and use
**Measure MacBook…** first. That fits the phone's correction on the MacBook's factory-calibrated
screen. Then calibrate each external display with the correction on.
