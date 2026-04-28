// Barbershop Harmonizer — MuseScore 3.x and MuseScore 4.x ≤ 4.5.
//
// (For MuseScore 4.6+, use bsh-mu4.6.qml — same logic, themed UI components.)
//
// Builds barbershop voicings around a clicked anchor note. Supports two layouts:
//   * Single-staff: all four voices stacked into one chord on the lead's track.
//   * Split-staff (TTBB): tenor/lead share the top staff (voices 1/2, stems
//     up/down); bari/bass share the staff below (voices 1/2, stems up/down).
//
// Key features:
//   * Sustained-lead anchoring — click any voice on a beat and the chord/voicing
//     UI is built around whichever voice-2 (or voice-1 fallback) is sounding the
//     lead pitch at that tick, even if it started in an earlier measure.
//   * Auto-detection of the existing chord at the clicked tick on selection
//     change, so the UI shows what's already there instead of stale state.
//   * Robust placement on empty voices, sustained-rest splits, and verification
//     after every cursor write.

import QtQuick 2.9
import QtQuick.Controls 1.3
import QtQuick.Layouts 1.4
import MuseScore 3.0

MuseScore {
    menuPath: "Plugins.Barbershop Harmonizer"
    description: "Plugin to help harmonizing a melody in Barbershop style"
    version: "1.1"
    pluginType: "dock"
    dockArea: "right"
    width: 370
    height: 500
    visible: true

    Component.onCompleted: {
        if (mscoreMajorVersion >= 4) {
            title = "Barbershop Harmonizer";
            categoryCode = "composing-arranging-tools";
            pluginType = "dialog";
        }
    }

    onRun: {
        main_cursor = curScore.newCursor();
        main_cursor.rewind(Cursor.SCORE_START);
        selection_changed();
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onEntered: selection_changed()
    }

    onScoreStateChanged: function (state) {
        // Plugin creator bug: this signal stays connected after the plugin stops.
        if (parent === null) return;
        if (inCmd) return;        // prevent recursion from own changes
        if (state.undoRedo) return;  // try not to interfere with undo/redo
        if (state.selectionChanged) selection_changed();
    }

    property bool inCmd: false
    property var main_cursor: undefined
    property int current_keysig: 0
    property int tonality: tona_from_ks[current_keysig + 7]
    property bool use_flats: current_keysig <= 0
    property int root: tonality + root_gv.model.get(root_gv.currentIndex).offset
    property var chord: chord_gv.model.get(chord_gv.currentIndex)
    property int lead_note: 60
    property bool interaction_enabled: false
    property var lead_note_track: 1
    property var lead_note_tick
    property var lead_note_element
    property var anchor_track         // track of the user's clicked note (may differ from lead_note_track)
    property var last_detected_tick   // tick of the last selection we ran auto-detect for
    property var last_detected_track  // track of the last selection we ran auto-detect for

    // Which TTBB voice carries the melody (anchor for chord voicings). Lead by
    // default; once the user toggles, the choice sticks for the session.
    property string melody_part: "lead"
    // Position in the 4-char voicing string corresponding to melody_part:
    //   0 = bass, 1 = bari, 2 = lead, 3 = tenor.
    property int melody_idx: melody_part === "tenor" ? 3
                           : melody_part === "lead"  ? 2
                           : melody_part === "bari"  ? 1
                           : melody_part === "bass"  ? 0
                           : 2

    ColumnLayout {
        id: columnLayout
        width: parent.width - 20
        height: parent.height - 20
        anchors.centerIn: parent

        Text {
            text: "Tonality : <b>" + get_note_name(tonality) + " major</b> (using " + (use_flats ? 'flats' : 'sharps') + ')'
        }

        Text {
            text: qsTr("Select root :")
        }

        GridView {
            id: root_gv
            Layout.minimumHeight: 2 * cellHeight
            Layout.fillWidth: true
            cellWidth: Math.floor(parent.width / 7)
            cellHeight: 30

            model: ListModel {
                ListElement { name: 'I'; offset: 0 }
                ListElement { name: 'II'; offset: 2 }
                ListElement { name: 'III'; offset: 4 }
                ListElement { name: 'IV'; offset: 5 }
                ListElement { name: 'V'; offset: 7 }
                ListElement { name: 'VI'; offset: 9 }
                ListElement { name: 'VII'; offset: 11 }
                ListElement { name: ''; offset: 6 }
                ListElement { name: ''; offset: 8 }
                ListElement { name: ''; offset: 10 }
                ListElement { name: ''; offset: 11 }
                ListElement { name: ''; offset: 1 }
                ListElement { name: ''; offset: 3 }
                ListElement { name: ''; offset: 5 }
            }

            delegate: Rectangle {
                width: root_gv.cellWidth - 2
                height: root_gv.cellHeight - 2
                color: "transparent"
                border.color: "lightgray"
                border.width: 1
                radius: 4
                enabled: interaction_enabled

                Text {
                    anchors.centerIn: parent
                    text: {
                        if (name != '')
                            '<font color="gray">' + name + "</font> <b>"
                                    + get_note_name(tonality + offset) + "</b>"
                        else
                            get_note_name(tonality + offset)
                    }
                    color: enabled ? "black" : "gray"
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root_gv.currentIndex = index
                }
            }
            highlight: Rectangle {
                color: "lightsteelblue"
                radius: 4
            }
        }

        Text {
            text: "Select chord :"
        }

        GridView {
            id: chord_gv
            Layout.minimumHeight: 2 * cellHeight
            Layout.fillWidth: true
            cellWidth: Math.floor(parent.width / 7)
            cellHeight: 30

            model: chords_model

            delegate: Rectangle {
                width: chord_gv.cellWidth - 2
                height: chord_gv.cellHeight - 2
                color: "transparent"
                border.color: "lightgray"
                border.width: 1
                radius: 4
                enabled: interaction_enabled

                Text {
                    anchors.centerIn: parent
                    text: get_note_name(root) + notation

                    color: (Object.keys(offsets).some(function (k) {
                        return (offsets[k] + root) % 12 === lead_note % 12;
                    })) && enabled ? "black" : "gray"
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: chord_gv.currentIndex = index
                }
            }
            highlight: Rectangle {
                color: "lightsteelblue"
                radius: 4
            }
        }

        Text {
            text: "Melody part :"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 25
                color: melody_part === "tenor" ? "lightsteelblue" : "transparent"
                border.color: "lightgray"
                border.width: 1
                radius: 4
                Text { anchors.centerIn: parent; text: "Tenor" }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { melody_part = "tenor"; selection_changed(); }
                }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 25
                color: melody_part === "lead" ? "lightsteelblue" : "transparent"
                border.color: "lightgray"
                border.width: 1
                radius: 4
                Text { anchors.centerIn: parent; text: "Lead" }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { melody_part = "lead"; selection_changed(); }
                }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 25
                color: melody_part === "bari" ? "lightsteelblue" : "transparent"
                border.color: "lightgray"
                border.width: 1
                radius: 4
                Text { anchors.centerIn: parent; text: "Bari" }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { melody_part = "bari"; selection_changed(); }
                }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 25
                color: melody_part === "bass" ? "lightsteelblue" : "transparent"
                border.color: "lightgray"
                border.width: 1
                radius: 4
                Text { anchors.centerIn: parent; text: "Bass" }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { melody_part = "bass"; selection_changed(); }
                }
            }
        }

        Text {
            text: "Choose voicing :"
        }

        GridView {
            id: voicing_gv
            Layout.fillWidth: true
            Layout.minimumHeight: cellHeight
            cellWidth: 25
            cellHeight: 70

            // Apply the auto-detected voicing index whenever the model changes
            // (i.e. the user picked a different chord type, or selection_changed
            // queued a target via voicing_gv.pending_voicing). GridView resets
            // currentIndex to 0 on model change, so we have to re-pick after.
            property string pending_voicing: ""
            onModelChanged: apply_pending_voicing()
            function apply_pending_voicing() {
                if (!pending_voicing || !model || !model.count) return;
                for (var j = 0; j < model.count; j++) {
                    if (model.get(j).notes === pending_voicing) {
                        currentIndex = j;
                        return;
                    }
                }
            }

            model: {
                if (typeof chord !== 'undefined') {
                    switch (chord.name) {
                    case 'minor':
                    case 'major':
                        triad_voicings
                        break;
                    case 'augmented':
                        aug_voicings
                        break;
                    case 'diminished':
                        dim_voicings
                        break;
                    case 'seventh':
                    case 'minor seventh':
                    case 'half-diminished seventh':
                        seventh_voicings
                        break;
                    case 'diminished seventh':
                        dim7_voicings
                        break;
                    case 'sixth':
                        sixth_voicings
                        break;
                    case 'ninth':
                        ninth_voicings
                        break;
                    case 'major with added ninth':
                        add9_voicings
                        break;
                    case 'minor with added sixth':
                        madd6_voicings
                        break;
                    case 'major seventh':
                        maj7_voicings
                        break;
                    }
                }
            }

            delegate: Rectangle {
                width: voicing_gv.cellWidth - 2
                height: voicing_gv.cellHeight - 2
                color: "transparent"
                border.color: "lightgray"
                border.width: 1
                radius: 4

                // True when the voicing's melody-position function lines up with
                // the actual anchor pitch — i.e. picking it would keep the user
                // in barbershop style. The "melody position" depends on the
                // melody_part toggle; defaults to position 2 (lead).
                property bool is_in_style: (typeof chord !== 'undefined')
                    && (root + chord.offsets[notes[melody_idx]]) % 12 == lead_note % 12

                enabled: (typeof chord !== 'undefined')
                         && interaction_enabled
                         && (is_in_style || out_of_style_cb.checked)

                Text {
                    anchors.centerIn: parent
                    text: notes[3] + '<br><b>' + notes[2] + '</b><br>' + notes[1] + '<br>' + notes[0]
                    // In-style voicings render in the primary color; out-of-style
                    // voicings are yellow when the override is on, gray otherwise.
                    color: !enabled ? "gray"
                         : is_in_style ? "black"
                         : "gold"
                }

                MouseArea {
                    hoverEnabled: true
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: {
                        voicing_selected(index, mouse.button == Qt.RightButton);
                    }
                    onEntered: {
                        status_bar.text = 'Tenor : ' + function_names[notes[3]]
                                       + '<br>Lead : ' + function_names[notes[2]]
                                       + '<br>Bari : ' + function_names[notes[1]]
                                       + '<br>Bass : ' + function_names[notes[0]]
                                       + '<br><font color="gray">Left-click : closed voicing'
                                       + '<br>Right-click : spread voicing</font>';
                    }
                    onExited: status_bar.text = ''
                }
            }
            highlight: Rectangle {
                color: "lightsteelblue"
                radius: 4
            }
        }

        RowLayout {
            ColumnLayout {
                Text {
                    id: status_bar
                    Layout.fillHeight: true
                    verticalAlignment: Text.AlignBottom
                    horizontalAlignment: Text.AlignLeft
                }

                Text {
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignLeft
                    text: {
                        var str = '';
                        if (typeof chord !== 'undefined') {
                            str = get_note_name(root) + chord.notation + " (" + chord.name + ")"
                                    + '<br>Current note : <font color="' + "lightsteelblue" + '">'
                                    + get_note_name(lead_note) + '</font>';
                            var interval = (lead_note + 12 - root) % 12;
                            if (interval > 0) {
                                str += ' is a ' + interval_names[interval] + ' above ' + get_note_name(root);
                            } else {
                                str += ' is the root of the chord';
                            }
                        }
                        str
                    }
                }
            } // ColumnLayout

            ColumnLayout {
                Rectangle {
                    Layout.fillHeight: true
                }

                CheckBox {
                    id: add_harmony_cb
                    text: "Add chord symbols"
                    onClicked: checked = !checked
                }

                CheckBox {
                    id: split_staff_cb
                    text: "Split staff (TTBB)"
                    checked: true
                    onClicked: checked = !checked
                }

                CheckBox {
                    id: out_of_style_cb
                    text: checked
                        ? 'Allow <font color="gold">out-of-style</font> voicings'
                        : 'Allow out-of-style voicings'
                }

                Button {
                    Layout.fillWidth: true
                    iconName: "help-about"
                    text: "Help"
                    onClicked: popup.visible = true
                }
            }
        } // RowLayout
    } // ColumnLayout

    // ============= Information Popup =============
    Rectangle {
        id: popup
        anchors.fill: parent
        color: "#77000000"
        visible: false
        z: 100

        property int popup_width: width - 40
        property int popup_height: height - 80

        MouseArea {
            anchors.fill: parent
            onClicked: popup.visible = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: popup.popup_width
            height: popup.popup_height
            color: "white"
            border.color: "black"
            radius: 4

            Text {
                anchors.fill: parent
                anchors.margins: 10
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignLeft
                verticalAlignment: Text.AlignTop
                text: "<h3>Barbershop Harmonizer</h3>"
                    + "<p>Tonality is determined automatically from the key signature.</p>"
                    + "<p>Select the lead note you want to harmonize. Select the root of the chord, then select the chord type. "
                    + "Click on the desired voicing to apply the change to the accompanying notes (Tenor, Baritone, and Bass). "
                    + "Right-click on the desired voicing to have a lower Baritone/bass pair (ie. to ensure that the Baritone is below the Lead).</p>"
                    + "<p><b>Split staff (TTBB):</b> when checked, Tenor goes on the lead's staff (voice 1, stem up), Lead stays on its voice (stem down), "
                    + "Bari and Bass go on the staff below (voices 1 and 2, stems up/down).</p>"
                    + "<p><i>Click anywhere outside this box to close.</i></p>"
            }
        }
    }

    // =========== Chords =================
    property ListModel chords_model: ListModel {
        Component.onCompleted: {
            append({ name: "major",                     notation: "",       offsets: {1: 0, 3: 4, 5: 7} })
            append({ name: "seventh",                   notation: "7",      offsets: {1: 0, 3: 4, 5: 7, 7: 10} })
            append({ name: "half-diminished seventh",   notation: "07",     offsets: {1: 0, 3: 3, 5: 6, 7: 10} })
            append({ name: "augmented",                 notation: "+",      offsets: {1: 0, 3: 4, 5: 8} })
            append({ name: "ninth",                     notation: "9",      offsets: {1: 0, 3: 4, 5: 7, 7: 10, 9: 2} })
            append({ name: "sixth",                     notation: "6",      offsets: {1: 0, 3: 4, 5: 7, 6: 9} })
            append({ name: "major seventh",             notation: "M7",     offsets: {1: 0, 3: 4, 5: 7, 7: 11} })
            append({ name: "minor",                     notation: "m",      offsets: {1: 0, 3: 3, 5: 7} })
            append({ name: "minor seventh",             notation: "m7",     offsets: {1: 0, 3: 3, 5: 7, 7: 10} })
            append({ name: "diminished seventh",        notation: "o7",     offsets: {1: 0, 3: 3, 5: 6, 7: 9} })
            append({ name: "diminished",                notation: "o",      offsets: {1: 0, 3: 3, 5: 6} })
            append({ name: "major with added ninth",    notation: "add9",   offsets: {1: 0, 3: 4, 5: 7, 9: 2} })
            append({ name: "minor with added sixth",    notation: "madd6",  offsets: {1: 0, 3: 3, 5: 7, 6: 9} })
        }
    }

    // ============= Voicings ===============
    readonly property ListModel seventh_voicings: ListModel {
        ListElement { notes: "5317" }
        ListElement { notes: "5713" }

        ListElement { notes: "1537" }
        ListElement { notes: "1735" }
        ListElement { notes: "5137" }
        ListElement { notes: "5731" }

        ListElement { notes: "1357" }
        ListElement { notes: "1753" }

        ListElement { notes: "1375" }
        ListElement { notes: "1573" }
        ListElement { notes: "5173" }
        ListElement { notes: "5371" }
    }

    readonly property ListModel ninth_voicings: ListModel {
        ListElement { notes: "5793" }
        ListElement { notes: "5397" }
        ListElement { notes: "1793" }

        // Si on veut avoir le ténor une tierce au dessus du lead
        ListElement { notes: "1379" } // ?
    }

    readonly property ListModel sixth_voicings: ListModel {
        ListElement { notes: "1361" }
        ListElement { notes: "1163" }
        ListElement { notes: "1365" }
    }

    readonly property ListModel madd6_voicings: ListModel {
        ListElement { notes: "1563" }
        ListElement { notes: "1356" }
        ListElement { notes: "1653" }
        ListElement { notes: "1635" }
    }

    readonly property ListModel maj7_voicings: ListModel {
        ListElement { notes: "1573" }
        ListElement { notes: "1375" }
    }

    readonly property ListModel add9_voicings: ListModel {
        ListElement { notes: "1593" }
        ListElement { notes: "1395" }
    }

    readonly property ListModel aug_voicings: ListModel {
        ListElement { notes: "1153" }
        ListElement { notes: "1351" }
    }

    readonly property ListModel dim7_voicings: ListModel {
        ListElement { notes: "1375" }
        ListElement { notes: "1735" }
        ListElement { notes: "3715" }
        ListElement { notes: "5713" }
    }

    readonly property ListModel dim_voicings: ListModel {
        ListElement { notes: "1351" }
    }

    readonly property ListModel triad_voicings: ListModel {
        ListElement { notes: "1513" }
        ListElement { notes: "1531" }
        ListElement { notes: "1153" }
        ListElement { notes: "1351" }
        ListElement { notes: "1355" }

        ListElement { notes: "3515" }
        ListElement { notes: "3151" }
        ListElement { notes: "3155" }

        ListElement { notes: "5135" }
        ListElement { notes: "5153" }
        ListElement { notes: "5351" }
    }

    property var note_names: {
        if (use_flats)
            ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B']
        else
            ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
    }

    property var note_tpc: {
        if (use_flats)
            [14, 9, 16, 11, 18, 13, 8, 15, 10, 17, 12, 19]
        else
            [14, 21, 16, 23, 18, 13, 20, 15, 22, 17, 24, 19]
    }

    readonly property var tona_from_ks: [11, 6, 1, 8, 3, 10, 5, 0, 7, 2, 9, 4, 11, 6, 1]

    readonly property var interval_names: [
        'unisson',
        'minor ninth',
        'major ninth',
        'minor third',
        'major third',
        'perfect fourth',
        'tritone',
        'perfect fifth',
        'minor sixth',
        'major sixth', //' / diminished seventh',
        'minor seventh',
        'major seventh',
        'octave',
    ]

    readonly property var function_names: {
        1: 'root',
        3: 'third',
        5: 'fifth',
        6: 'sixth',
        7: 'seventh',
        9: 'ninth',
    }

    // ===================== Functions =====================

    function ensureCmdStarted() {
        if (!inCmd) {
            curScore.startCmd();
            inCmd = true;
        }
    }

    function ensureCmdEnded() {
        if (inCmd) {
            curScore.endCmd();
            inCmd = false;
        }
    }

    function get_note_name(pitch) {
        return note_names[pitch % 12]
    }

    function get_tpc(pitch) {
        return note_tpc[pitch % 12]
    }

    function selection_changed() {
        interaction_enabled = false;

        if (curScore.selection.elements.length !== 1) return;
        var el = curScore.selection.elements[0];
        if (el.type !== Element.NOTE) return;

        interaction_enabled = true;

        var clicked_tick  = el.parent.parent.tick;
        var clicked_track = el.track;

        // The clicked element/tick is the ANCHOR — where the harmony will be
        // placed and what we re-select after the operation.
        lead_note_element = el;
        lead_note_tick    = clicked_tick;
        anchor_track      = clicked_track;

        // Find the lead voice's track for TTBB layout derivation. lead_note_track
        // always points to the actual lead voice (used by ttbb_tracks), even
        // when the melody is on a different part.
        var lead_info = find_lead_at(clicked_track, clicked_tick);
        lead_note_track = lead_info ? lead_info.track : clicked_track;

        // Determine the anchor pitch — the pitch of the melody voice at this
        // tick. For melody=lead, use the sustained-lead pitch (lead_info or
        // clicked element). For other melody parts, walk the corresponding
        // TTBB track and pick the pitch of whatever chord covers the click tick.
        if (melody_part === "lead") {
            if (lead_info && lead_info.track !== clicked_track) {
                lead_note = lead_info.pitch;
            } else {
                lead_note = el.pitch;
            }
        } else {
            var tracks = ttbb_tracks(lead_note_track);
            var melody_track = melody_part === "tenor" ? tracks.tenor
                             : melody_part === "bari"  ? tracks.bari
                             : melody_part === "bass"  ? tracks.bass
                             : lead_note_track;
            var melody_chord = track_chord_covering(melody_track, clicked_tick);
            if (melody_chord && melody_chord.notes && melody_chord.notes.length > 0) {
                lead_note = melody_chord.notes[0].pitch;
            } else {
                lead_note = el.pitch;
            }
        }

        main_cursor.rewindToTick(clicked_tick);
        current_keysig = main_cursor.keySignature;

        // Auto-detect the current chord and update the root/chord/voicing UI —
        // but only when the anchor actually changed. selection_changed also
        // fires on plugin-window hover (MouseArea.onEntered), and re-snapping
        // the UI to the existing chord every hover stomps on in-progress picks.
        if (clicked_tick !== last_detected_tick
                || clicked_track !== last_detected_track) {
            last_detected_tick  = clicked_tick;
            last_detected_track = clicked_track;
            try {
                var detection = detect_current_chord(clicked_tick, lead_note_track);
                if (detection) update_ui_for_chord(detection);
            } catch (e) {
                console.log("auto-detect chord error: " + e);
            }
        }
    }

    function voicing_selected(index, spread) {
        var voicing = voicing_gv.model.get(index);

        // Compute pitches for all four voices [bass, bari, lead, tenor] such
        // that the melody voice (per the melody_part toggle) lands on the
        // user's anchor pitch. Voicing string is "<bass><bari><lead><tenor>"
        // where each char is a chord function digit (1, 3, 5, 6, 7, 9).
        var pitches    = compute_pitches(voicing, melody_idx, lead_note, spread);
        var bass_note  = pitches[0];
        var bari_note  = pitches[1];
        var lead_pitch = pitches[2];
        var tenor_note = pitches[3];

        ensureCmdStarted();

        if (split_staff_cb.checked) {
            change_pitch_split_staff(tenor_note, lead_pitch, bari_note, bass_note);
        } else {
            // Single-staff: stack the three non-melody voices into the anchor's chord.
            var others = [];
            for (var k = 0; k < 4; k++) {
                if (k !== melody_idx) others.push(pitches[k]);
            }
            change_pitch(lead_note_track, others);
        }

        // Chord symbol goes at the anchor tick (where the chord change happens),
        // not at the start of any tie chain.
        main_cursor.rewindToTick(lead_note_tick);
        var harmony = get_segment_harmony(main_cursor.segment);
        var chord_name = get_note_name(root) + chord.notation;

        if (harmony) {
            harmony.text = chord_name;
        } else if (add_harmony_cb.checked) {
            harmony = newElement(Element.HARMONY);
            main_cursor.add(harmony);
            harmony.text = chord_name;
        }

        ensureCmdEnded();
    }

    // Single-staff mode: stack tenor/bari/bass on the lead's chord, removing any
    // previous harmony notes first. Preserves the lead pitch and any ties on it.
    function change_pitch(track, notes) {
        main_cursor.track = track;
        main_cursor.rewind(1);

        var chord = curScore.selection.elements[0].parent;
        var lead_note_local;
        for (var i = chord.notes.length - 1; i >= 0; i--) {
            var n = chord.notes[i];
            if (n.pitch !== lead_note) {
                while (n.tieForward) removeElement(n.lastTiedNote);
                while (n.tieBack)    removeElement(n.firstTiedNote);
                removeElement(n);
            } else {
                lead_note_local = n;
            }
        }

        for (var j = 0; j < notes.length; j++) {
            main_cursor.addNote(notes[j], true);
        }
        if (lead_note_local) curScore.selection.select(lead_note_local, false);
    }

    // Split-staff TTBB: place tenor on the lead's staff (opposite voice from lead),
    // and bari/bass on the staff directly below.
    //   Tenor: voice 1 of lead's staff  -> stem up
    //   Lead : voice 2 of lead's staff (or whichever voice the lead lives on) -> stem down
    //   Bari : voice 1 of staff below   -> stem up
    //   Bass : voice 2 of staff below   -> stem down
    //
    // The lead's pitch is preserved when melody_part === "lead" (and ties on it
    // are kept). For other melody parts, the lead voice is rewritten in place
    // and the chosen melody voice keeps its pitch via the in-place modify path
    // in set_voice_pitch.
    function change_pitch_split_staff(tenor_pitch, lead_pitch, bari_pitch, bass_pitch) {
        var tracks = ttbb_tracks(lead_note_track);
        var lead_staff  = tracks.lead_staff;
        var tenor_track = tracks.tenor;
        var bari_track  = tracks.bari;
        var bass_track  = tracks.bass;
        var lead_voice  = tracks.lead_voice;
        // Stem direction enum: AUTO=0, UP=1, DOWN=2. Voice 2 stems down, voice 1 up.
        var lead_stem   = (lead_voice === 0) ? 1 : 2;

        // Duration for the harmony comes from the CLICKED element. When the user
        // clicks tenor/bari/bass on a beat where the lead is sustaining, this
        // makes the harmony note match the click's beat duration rather than
        // the lead's full sustained duration.
        var clicked_chord = lead_note_element.parent;
        var clicked_dur   = clicked_chord.duration;
        var durNum        = clicked_dur.numerator;
        var durDen        = clicked_dur.denominator;

        // Locate the lead's chord by walking the lead's track for whatever covers
        // the anchor tick — it may start before lead_note_tick if the lead is
        // sustaining a longer note.
        var lead_chord = track_chord_covering(lead_note_track, lead_note_tick);
        if (lead_chord && melody_part === "lead") {
            // Lead is the melody — preserve its existing pitch (and ties), strip extras.
            for (var i = lead_chord.notes.length - 1; i >= 0; i--) {
                var n = lead_chord.notes[i];
                if (n.pitch != lead_note) {
                    while (n.tieForward) { removeElement(n.lastTiedNote); }
                    while (n.tieBack)    { removeElement(n.firstTiedNote); }
                    removeElement(n);
                }
            }
            lead_chord.stemDirection = lead_stem;
        }

        // Refuse to write to tracks that don't exist (e.g. score has only one staff).
        var max_track = curScore.nstaves * 4;
        if (bass_track >= max_track) {
            console.log("change_pitch_split_staff: ABORT — score has only " + curScore.nstaves
                        + " staves, need at least " + (lead_staff + 2)
                        + " for split-staff TTBB starting on staff " + lead_staff);
            return;
        }

        set_voice_pitch(tenor_track, lead_note_tick, tenor_pitch, 1, durNum, durDen);
        if (melody_part !== "lead") {
            // Lead is being rewritten — write its new pitch alongside the others.
            set_voice_pitch(lead_note_track, lead_note_tick, lead_pitch, lead_stem, durNum, durDen);
        }
        set_voice_pitch(bari_track,  lead_note_tick, bari_pitch,  1, durNum, durDen);
        set_voice_pitch(bass_track,  lead_note_tick, bass_pitch,  2, durNum, durDen);

        // Re-select the note at the user's original click position. The original
        // element reference is invalidated when set_voice_pitch replaces the chord
        // on that track, so look it up fresh by (anchor_track, anchor_tick).
        var anchor_chord = track_element_at(anchor_track, lead_note_tick);
        if (anchor_chord && anchor_chord.type == Element.CHORD
                && anchor_chord.notes && anchor_chord.notes.length > 0) {
            curScore.selection.select(anchor_chord.notes[0], false);
        } else if (lead_chord && lead_chord.notes.length > 0) {
            curScore.selection.select(lead_chord.notes[0], false);
        }
    }

    // Compute target pitches [bass, bari, lead, tenor] for a voicing, given the
    // chord (root + type), the anchor index (0..3, which voice is the melody),
    // the anchor pitch (the user's clicked / sustained pitch on that voice),
    // and the spread flag.
    //
    // Approach: build a reference voicing using the original lead-anchored
    // algorithm (which encodes traditional barbershop pitch ordering — bari above
    // lead by default, bass dropped low for resonance, etc.), with the lead at a
    // pitch close to anchor_pitch's octave but matching the voicing's prescribed
    // lead pc. Then shift the whole chord by the octave delta needed to land the
    // anchor voice on anchor_pitch. For in-style voicings this preserves the
    // anchor exactly; for out-of-style picks the shift rounds to the nearest
    // octave so the result stays in roughly the user's range.
    function compute_pitches(voicing, anchor_idx, anchor_pitch, spread) {
        var lead_pc  = ((root + chord.offsets[voicing.notes[2]]) % 12 + 12) % 12;
        var ref_lead = lead_pc + 12 * Math.round((anchor_pitch - lead_pc) / 12);

        var ref = compute_lead_anchored_pitches(voicing, ref_lead, spread);

        var ref_pc    = ((ref[anchor_idx] % 12) + 12) % 12;
        var anchor_pc = ((anchor_pitch    % 12) + 12) % 12;

        var diff = (ref_pc === anchor_pc)
                ? anchor_pitch - ref[anchor_idx]
                : Math.round((anchor_pitch - ref[anchor_idx]) / 12) * 12;

        return [ref[0] + diff, ref[1] + diff, ref[2] + diff, ref[3] + diff];
    }

    // Original lead-anchored pitch placement: tenor above lead, bari above lead
    // (or below if spread / if it would otherwise collide with tenor), bass an
    // octave below bari.
    function compute_lead_anchored_pitches(voicing, lead_pitch, spread) {
        var tenor_note = root + chord.offsets[voicing.notes[3]];
        while (tenor_note <= lead_pitch) tenor_note += 12;

        var bari_note = root + chord.offsets[voicing.notes[1]];
        while (bari_note < lead_pitch) bari_note += 12;
        if (bari_note >= tenor_note) bari_note -= 12;
        if (spread) bari_note -= 12;

        var bass_note = root + chord.offsets[voicing.notes[0]];
        while (bass_note < bari_note && bass_note < lead_pitch) bass_note += 12;
        bass_note -= 12;

        return [bass_note, bari_note, lead_pitch, tenor_note];
    }

    // Place a single pitch on the given track at the given tick, guaranteeing
    // that on success the track has a chord starting at exactly `tick` with
    // the lead's duration and our pitch — i.e. a parallel voice to the anchor.
    //
    // Three input situations, all handled:
    //   (a) A chord already starts at `tick` with the lead's duration.
    //       -> Modify pitch in place (preserves ties to neighboring chords).
    //   (b) A rest covers `tick` (the rest may start before `tick`, e.g. a
    //       full-measure rest in an empty voice).
    //       -> Drop a filler rest of length (tick - rest_start) at the rest's
    //          start, which splits it; then addNote with the lead's duration.
    //   (c) A chord covers `tick` but doesn't start there, OR a chord starts
    //       at `tick` with a wrong duration.
    //       -> Same approach as (b): the filler rest replaces the leading slice
    //          of the covering element, addNote replaces the trailing slice
    //          starting at `tick` with our note. Ties on the original chord
    //          are not preserved (acceptable: user is rewriting the harmony).
    //
    // Every step is bracketed by checks against fresh-cursor scans. If a
    // precondition fails, the per-track operation aborts with a diagnostic
    // rather than corrupting an unrelated note.
    function set_voice_pitch(track, tick, pitch, stemDir, durNum, durDen) {
        try {
            // Resolve what's actually starting at exactly (track, tick).
            var atTick = track_element_at(track, tick);

            // Case (a): chord at exact tick with matching duration → in-place modify.
            if (atTick && atTick.type == Element.CHORD
                    && fractions_equal(atTick.duration.numerator, atTick.duration.denominator,
                                       durNum, durDen)) {
                for (var i = atTick.notes.length - 1; i >= 1; i--) {
                    removeElement(atTick.notes[i]);
                }
                var n = atTick.notes[0];
                n.pitch = pitch;
                n.tpc1 = get_tpc(pitch);
                n.tpc2 = n.tpc1;
                while (n.tieForward != null) {
                    n = n.tieForward.endNote;
                    n.pitch = pitch;
                    n.tpc1 = get_tpc(pitch);
                    n.tpc2 = n.tpc1;
                }
                atTick.stemDirection = stemDir;
                return;
            }

            // Case (b): rest covers tick. Split it and place a parallel note.
            // We deliberately do NOT try to overwrite a chord that covers `tick`
            // without starting there (or starts there with a wrong duration) —
            // that path is more crash-prone and rare in practice. Bail out instead.
            var rest = track_rest_covering(track, tick);

            // Case (c): no rest found AND nothing starts at tick → the voice is
            // empty here (typical for voice 2 of a staff that's never had voice 2
            // content in this measure). Walking the cursor on the empty voice
            // itself is unreliable, so we walk on the lead's track (which is
            // guaranteed to have a segment at `tick`), then switch cursor.track
            // to the target voice while keeping the position. addNote then
            // creates voice content with auto-filled leading rests.
            if (!rest && !atTick) {
                main_cursor.track = lead_note_track;
                main_cursor.filter = Segment.ChordRest;
                main_cursor.rewind(0);
                while (main_cursor.tick < tick) {
                    if (!main_cursor.next()) break;
                }
                if (main_cursor.tick !== tick) {
                    console.log("set_voice_pitch: ABORT track=" + track + " tick=" + tick
                                + " — empty voice; couldn't reach tick on lead's track"
                                + " (landed at " + main_cursor.tick + ")");
                    return;
                }

                main_cursor.track = track;
                main_cursor.setDuration(durNum, durDen);
                main_cursor.addNote(pitch, false);

                var placed_empty = track_element_at(track, tick);
                if (!placed_empty || placed_empty.type != Element.CHORD
                        || !chord_has_pitch(placed_empty, pitch)) {
                    console.log("set_voice_pitch: VERIFY FAILED (empty voice) track="
                                + track + " tick=" + tick
                                + " — got=" + (placed_empty ? placed_empty.type : "null")
                                + " — falling back to filler-rest seeding");

                    // Fallback: seed voice 2 with an explicit rest cloned from the
                    // same-staff voice 1 (which always has at least an implicit
                    // measure rest). Once voice 2 has segment-level content, the
                    // normal split-and-insert path in case (b) will work on a
                    // subsequent call.
                    var staff_voice1_track = (track - (track % 4)) + 0;
                    var v1_rest = track_rest_covering(staff_voice1_track, tick);
                    if (!v1_rest || !v1_rest.element
                            || typeof v1_rest.element.clone !== "function") {
                        console.log("set_voice_pitch: ABORT (empty voice fallback) track="
                                    + track + " — no cloneable voice-1 rest at tick");
                        return;
                    }

                    main_cursor.track = staff_voice1_track;
                    main_cursor.rewindToTick(v1_rest.start);
                    main_cursor.track = track;
                    var seed = v1_rest.element.clone();
                    main_cursor.add(seed);

                    // Voice 2 should now have a rest; retry the split path.
                    var rest2 = track_rest_covering(track, tick);
                    if (!rest2) {
                        console.log("set_voice_pitch: ABORT (empty voice fallback) track="
                                    + track + " — seeding did not produce a rest");
                        return;
                    }
                    rest = rest2;
                    // fall through to the case (b) split logic below
                } else {
                    placed_empty.stemDirection = stemDir;
                    return;
                }
            }

            if (!rest) {
                console.log("set_voice_pitch: ABORT track=" + track + " tick=" + tick
                            + " — no rest covers this tick (atTick="
                            + (atTick ? atTick.type : "null") + ")");
                return;
            }

            var pre_ticks = tick - rest.start;
            if (pre_ticks < 0 || pre_ticks >= rest.duration_ticks) {
                console.log("set_voice_pitch: ABORT track=" + track + " tick=" + tick
                            + " — pre_ticks=" + pre_ticks + " out of bounds");
                return;
            }

            main_cursor.track = track;
            main_cursor.rewindToTick(rest.start);
            if (main_cursor.tick !== rest.start) {
                console.log("set_voice_pitch: ABORT track=" + track + " tick=" + tick
                            + " — cursor failed to reach rest.start=" + rest.start
                            + " (landed at " + main_cursor.tick + ")");
                return;
            }

            // Insert a filler rest to consume the gap before `tick`. We clone the
            // existing rest rather than constructing one with newElement(Element.REST),
            // which has been observed to crash MS4 when the resulting rest is added
            // to the cursor.
            if (pre_ticks > 0) {
                var pre = ticks_to_frac(pre_ticks);
                if (!rest.element || typeof rest.element.clone !== "function") {
                    console.log("set_voice_pitch: ABORT track=" + track + " tick=" + tick
                                + " — covering rest is not cloneable");
                    return;
                }
                var filler = rest.element.clone();
                filler.duration = fraction(pre[0], pre[1]);
                main_cursor.add(filler);

                var split_check = track_element_at(track, tick);
                if (!split_check) {
                    console.log("set_voice_pitch: ABORT track=" + track + " tick=" + tick
                                + " — split did not produce an element at target tick");
                    return;
                }
            }

            main_cursor.rewindToTick(tick);
            if (main_cursor.tick !== tick) {
                console.log("set_voice_pitch: ABORT track=" + track + " tick=" + tick
                            + " — cursor failed to reach target tick"
                            + " (landed at " + main_cursor.tick + ")");
                return;
            }
            main_cursor.setDuration(durNum, durDen);
            main_cursor.addNote(pitch, false);

            var placed = track_element_at(track, tick);
            if (!placed || placed.type != Element.CHORD) {
                console.log("set_voice_pitch: VERIFY FAILED track=" + track + " tick=" + tick
                            + " — no chord at target tick after addNote (got="
                            + (placed ? placed.type : "null") + ")");
                return;
            }
            if (!chord_has_pitch(placed, pitch)) {
                console.log("set_voice_pitch: VERIFY FAILED track=" + track + " tick=" + tick
                            + " — chord at target tick missing pitch=" + pitch);
                return;
            }
            placed.stemDirection = stemDir;
        } catch (e) {
            console.log("set_voice_pitch: EXCEPTION track=" + track + " tick=" + tick
                        + " pitch=" + pitch + ": " + e);
        }
    }

    // Walk `track` from the start of the score and return the element starting
    // exactly at `tick`, or null if nothing on this track starts there.
    function track_element_at(track, tick) {
        var c = curScore.newCursor();
        c.track = track;
        c.filter = Segment.ChordRest;
        c.rewind(0);
        while (c.segment) {
            if (c.tick === tick) {
                return c.element || null;
            }
            if (c.tick > tick) return null;
            if (!c.next()) break;
        }
        return null;
    }

    // Inspect tracks 0/1/4/5 (or whichever match the lead's staff and the staff
    // below) at `tick`, deduce a chord identity (root + type + voicing), and
    // return { root_pc, chord_index, voicing_str } — or null if four notes
    // aren't present, or no chord type contains them.
    function detect_current_chord(tick, lead_track) {
        try {
        var tracks = ttbb_tracks(lead_track);

        var t_chord = track_chord_covering(tracks.tenor, tick);
        var l_chord = track_chord_covering(lead_track,   tick);
        var b_chord = track_chord_covering(tracks.bari,  tick);
        var s_chord = track_chord_covering(tracks.bass,  tick);

        if (!t_chord || !l_chord || !b_chord || !s_chord) return null;

        var t_pc = t_chord.notes[0].pitch % 12;
        var l_pc = l_chord.notes[0].pitch % 12;
        var b_pc = b_chord.notes[0].pitch % 12;
        var s_pc = s_chord.notes[0].pitch % 12;

        var pcs_obj = {};
        pcs_obj[t_pc] = true; pcs_obj[l_pc] = true;
        pcs_obj[b_pc] = true; pcs_obj[s_pc] = true;
        var pcs = Object.keys(pcs_obj).map(Number);

        var best = null;
        for (var i = 0; i < chords_model.count; i++) {
            var def = chords_model.get(i);
            var offsets = def.offsets;
            var fn_keys = Object.keys(offsets);

            for (var root_pc = 0; root_pc < 12; root_pc++) {
                var chord_pcs_obj = {};
                fn_keys.forEach(function(k) {
                    chord_pcs_obj[(root_pc + offsets[k]) % 12] = true;
                });
                var chord_pcs = Object.keys(chord_pcs_obj).map(Number);

                var subset = pcs.every(function(pc) { return chord_pcs.indexOf(pc) !== -1; });
                if (!subset) continue;

                if (best === null || chord_pcs.length < best.chord_pcs_len) {
                    best = {
                        root_pc: root_pc,
                        chord_index: i,
                        chord_def: def,
                        chord_pcs_len: chord_pcs.length
                    };
                }
            }
        }

        if (!best) return null;

        // Build the voicing string "<bass><bari><lead><tenor>" from chord functions.
        var defOff = best.chord_def.offsets;
        var fn_for = function(pc) {
            for (var k in defOff) {
                if ((best.root_pc + defOff[k]) % 12 === pc) return k;
            }
            return null;
        };
        var voicing_str = "" + (fn_for(s_pc) || "") + (fn_for(b_pc) || "")
                            + (fn_for(l_pc) || "") + (fn_for(t_pc) || "");
        if (voicing_str.length !== 4) voicing_str = null;

        return {
            root_pc: best.root_pc,
            chord_index: best.chord_index,
            voicing_str: voicing_str
        };
        } catch (e) {
            console.log("detect_current_chord error: " + e);
            return null;
        }
    }

    // Apply detect_current_chord's result to the root_gv, chord_gv, voicing_gv
    // grids, highlighting the matched chord. Voicing index is staged via
    // voicing_gv.pending_voicing; when the chord change propagates to
    // voicing_gv.model and the GridView resets currentIndex, voicing_gv's
    // onModelChanged hook re-applies it from pending_voicing. The immediate
    // apply_pending_voicing() call covers the case where the model didn't
    // need to change (same chord type re-detected).
    function update_ui_for_chord(detection) {
        try {
            for (var i = 0; i < root_gv.model.count; i++) {
                var entry = root_gv.model.get(i);
                if ((tonality + entry.offset) % 12 === detection.root_pc) {
                    root_gv.currentIndex = i;
                    break;
                }
            }

            voicing_gv.pending_voicing = detection.voicing_str || "";
            chord_gv.currentIndex = detection.chord_index;
            voicing_gv.apply_pending_voicing();
        } catch (e) {
            console.log("update_ui_for_chord error: " + e);
        }
    }

    // Walk `track` and return the chord whose span covers `tick`
    // (start <= tick < start + duration), or null if none does. A "covering"
    // chord may start before `tick` — useful for finding sustained notes.
    function track_chord_covering(track, tick) {
        var c = curScore.newCursor();
        c.track = track;
        c.filter = Segment.ChordRest;
        c.rewind(0);
        while (c.segment) {
            var e = c.element;
            if (e && e.type == Element.CHORD) {
                var s = c.tick;
                var d = e.duration.ticks;
                if (s <= tick && tick < s + d) {
                    return e;
                }
            }
            if (c.tick > tick) return null;
            if (!c.next()) break;
        }
        return null;
    }

    // Identify the lead voice at `tick` given the user clicked on `clicked_track`.
    //
    // Standard TTBB has the lead on voice 2 of the top staff (stem down). Some
    // arrangements put it on voice 1 instead (stem up). Heuristic:
    //   Pass 1: scan voice 2 of every staff from the top down through the
    //           clicked staff. Skip the clicked track itself. First chord wins.
    //   Pass 2: if pass 1 found nothing, scan voice 1 of staves STRICTLY above
    //           the clicked staff. (Skipping the clicked staff in pass 2 avoids
    //           picking the tenor when the user clicked tenor on the top staff.)
    function find_lead_at(clicked_track, tick) {
        var clicked_staff = Math.floor(clicked_track / 4);

        for (var s = 0; s <= clicked_staff; s++) {
            var v2_track = s * 4 + 1;
            if (v2_track === clicked_track) continue;
            var v2_chord = track_chord_covering(v2_track, tick);
            if (v2_chord && v2_chord.notes && v2_chord.notes.length > 0) {
                return { track: v2_track, pitch: v2_chord.notes[0].pitch };
            }
        }

        for (var s2 = 0; s2 < clicked_staff; s2++) {
            var v1_track = s2 * 4;
            if (v1_track === clicked_track) continue;
            var v1_chord = track_chord_covering(v1_track, tick);
            if (v1_chord && v1_chord.notes && v1_chord.notes.length > 0) {
                return { track: v1_track, pitch: v1_chord.notes[0].pitch };
            }
        }

        return null;
    }

    // Walk `track` and return {element, start, duration_ticks} for the rest
    // whose span covers `tick` (start <= tick < start + duration). Returns
    // null if a chord covers the tick instead, or nothing covers it at all.
    function track_rest_covering(track, tick) {
        var c = curScore.newCursor();
        c.track = track;
        c.filter = Segment.ChordRest;
        c.rewind(0);
        while (c.segment) {
            var e = c.element;
            if (e) {
                var s = c.tick;
                var d = e.duration.ticks;
                if (s <= tick && tick < s + d) {
                    if (e.type == Element.REST) {
                        return { element: e, start: s, duration_ticks: d };
                    }
                    return null;
                }
            }
            if (c.tick > tick) return null;
            if (!c.next()) break;
        }
        return null;
    }

    function chord_has_pitch(chord, pitch) {
        for (var i = 0; i < chord.notes.length; i++) {
            if (chord.notes[i].pitch === pitch) return true;
        }
        return false;
    }

    // Given the lead's track, derive the four TTBB voice tracks.
    //   Tenor:  lead's staff, opposite voice from the lead (so they don't collide)
    //   Bari:   one staff below the lead, voice 1 (stem up by default)
    //   Bass:   one staff below the lead, voice 2 (stem down by default)
    function ttbb_tracks(lead_track) {
        var lead_staff = Math.floor(lead_track / 4);
        var lead_voice = lead_track % 4;
        return {
            lead_staff:  lead_staff,
            lead_voice:  lead_voice,
            tenor:       lead_staff * 4 + (lead_voice === 1 ? 0 : 1),
            bari:        (lead_staff + 1) * 4 + 0,
            bass:        (lead_staff + 1) * 4 + 1
        };
    }

    function fractions_equal(an, ad, bn, bd) {
        return an * bd === bn * ad;
    }

    // Reduce ticks to a (numerator, denominator) fraction relative to a whole note
    // (1920 ticks at MuseScore's default resolution).
    function ticks_to_frac(ticks) {
        var den = 1920;
        var num = ticks;
        var a = num < 0 ? -num : num;
        var b = den;
        while (b !== 0) { var t = b; b = a % b; a = t; }
        return [num / a, den / a];
    }

    // Copied from ChordIdentifierSp3_2
    function get_segment_harmony(segment) {
        //if (segment.segmentType != Segment.ChordRest)
        //    return null;
        var aCount = 0;
        var annotation = segment.annotations[aCount];
        while (annotation) {
            if (annotation.type == Element.HARMONY) {
                return annotation;
            }
            annotation = segment.annotations[++aCount];
        }
        return null;
    }
}
