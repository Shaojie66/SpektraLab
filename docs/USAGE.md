# Using SpektraLab

**English** · [简体中文](USAGE.zh-CN.md) · [Back to README](../README.md)

## Select and sync photos

Click a photo to make it the current photo, then Command-click other photos to
add or remove them without moving the current photo. Command+A (Edit → Select
All Photos) selects the library and keeps the current photo as the sync source.
In a newly opened folder it opens the first photo. Command+A inside a text field
still selects text.

Under Settings Clipboard, tick the groups to transfer and choose **Sync to N**
(or Edit → Sync Settings). This reads the current photo's latest edits, preserves
the clipboard and source photo, and saves the other selected photos immediately.
They develop with those settings when opened. Crop, Post-Dev adjustments, lens
correction, Film Edge and Date Back stay with each photo, following the existing
clipboard rules. As Shot white balance and fitted Scene Placement are resolved
for each target. Sync has no batch undo; the status reports writes and failures.
Selection and sync are disabled during batch export.

## Film Edge, Date Back and half-frame pairs

**Film Edge** (left rail) turns the canvas into the film: pick a format and the
frame is cut to its gate and shown on the strip, with the stock's own edge
print and a frame number you can set; a strip scan ends at the film's edges.
The crop becomes the framing in the gate, so it is part of the
negative. **Date Back** exposes the shooting date (or a date you type) into the
frame; it needs no film edge. With one, it can print the shooting data beside
the frame at the same time, and on 120 (645 to 6×9) the date and the data go
in the film margin, where a medium-format back printed them.

**A half-frame pair** is two frames on one frame's worth of 135. With Film Edge
on *Half*, **Enter Half-Frame Pair** appears under the format (or pick two
photos and press ⌘J). The canvas shows two holes; an empty one has a **+**.
Click a hole to pick its frame: Input / Camera, Scene Placement, the Enlarger
and Post-Dev then act on that frame alone, and *+ Film* moves the film around
it too. Right-click a hole to replace, turn or crop its frame. In the crop
mode, drag moves the picture under its hole and scroll or pinch scales it about
the pointer. A pair is one item in the filmstrip and exports as one picture.

Drag a thumbnail along the filmstrip to reorder a folder; the order is kept for
that folder. A file dropped from Finder still opens and edits.

