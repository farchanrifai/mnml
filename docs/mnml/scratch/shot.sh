#!/bin/zsh
# shot.sh <name> <probe args...>: runs the probe, screenshots its window to <name>.png, log in <name>.log.
cd ${0:h}; name=$1; shift
(./probe "$@" > $name.log 2>&1 &)
sleep 9
ID=$(swift -e 'import CoreGraphics; let l = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]; let w = l.filter { ($0["kCGWindowOwnerName"] as? String) == "probe" }.max { (($0["kCGWindowBounds"] as! [String: Double])["Width"]!) < (($1["kCGWindowBounds"] as! [String: Double])["Width"]!) }!; print(w["kCGWindowNumber"]!)')
screencapture -x -o -l $ID $name.png; sips -Z 900 $name.png >/dev/null
pkill -x probe; sleep 1
