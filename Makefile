QMLLINT := $(shell command -v qmllint 2>/dev/null || ls /usr/lib/qt6/bin/qmllint 2>/dev/null || echo qmllint)
QML_FILES := Panel.qml WifiSection.qml EthernetSection.qml StatsGrid.qml ProfileList.qml WifiScanList.qml

.PHONY: test qml-check validate

test:
	node tests/test_model.js

# Needs the Omarchy shell's qs.Ui / qs.Commons on the import path, so this
# stays local-only -- CI has no Omarchy install to point it at. Warnings
# about unresolved qs.* imports and the components built on them are
# expected noise from the same cause; qmllint's exit code only goes
# non-zero for a real error, which is the actual gate here.
qml-check:
	$(QMLLINT) -I /usr/share/omarchy/shell $(QML_FILES)

# Also local-only: needs the `omarchy` CLI, which CI doesn't have either.
validate: test qml-check
	omarchy plugin validate .
