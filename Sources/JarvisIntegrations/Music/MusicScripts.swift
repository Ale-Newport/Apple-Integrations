import Foundation

/// The AppleScript programs used by the Music integration.
///
/// Every program is a constant. Anything that depends on the user's command (search text, playlist ids, volume…)
/// arrives through `argv`. Results are returned as text using ASCII unit/record separators (see `ScriptRecords`).
/// Failures use `error "TAG|detail" number 90xx` so the Swift side can tell "not found" from "broken".
enum MusicScripts {
    private static func make(_ name: String, _ body: String) -> AppleScriptSource {
        AppleScriptSource(name: "music.\(name)", text: ScriptPrelude.handlers + "\n" + stateHandler + "\n" + body)
    }

    /// `stateRow()` → state, volume, shuffle, repeat, position, then the current track
    /// (persistent id, name, artist, album, duration seconds, cloud status, class) or seven empty fields.
    private static let stateHandler = #"""
    on stateRow()
    tell application "Music"
    set playerState to player state as text
    set vol to sound volume as text
    set shuf to shuffle enabled as text
    set rep to song repeat as text
    set pos to "0"
    try
    set pos to (round (player position)) as text
    end try
    set info to {"", "", "", "", "0", "", ""}
    try
    set t to current track
    set info to {persistent ID of t, my oneLine(name of t), my oneLine(artist of t), my oneLine(album of t), ((round (duration of t)) as text), ((cloud status of t) as text), ((class of t) as text)}
    end try
    end tell
    return my joinFields({playerState, vol, shuf, rep, pos} & info)
    end stateRow
    """#

    /// Current playback state.
    static let state = make("state", #"""
    on run argv
    return my stateRow()
    end run
    """#)

    /// argv: search text, kind (any|song|album|artist), limit → records of
    /// persistent id, name, artist, album, duration, cloud status, class, disc number, track number, year.
    static let search = make("search", #"""
    on run argv
    set q to item 1 of argv
    set kindName to item 2 of argv
    set limitCount to (item 3 of argv) as integer
    set rows to {}
    tell application "Music"
    if kindName is "song" then
    set res to search library playlist 1 for q only songs
    else if kindName is "album" then
    set res to search library playlist 1 for q only albums
    else if kindName is "artist" then
    set res to search library playlist 1 for q only artists
    else
    set res to search library playlist 1 for q
    end if
    if res is missing value then set res to {}
    set n to count of res
    if n > limitCount then set n to limitCount
    repeat with i from 1 to n
    set t to item i of res
    set discNo to "0"
    set trackNo to "0"
    set yr to "0"
    try
    set discNo to (disc number of t) as text
    set trackNo to (track number of t) as text
    set yr to (year of t) as text
    end try
    set row to {persistent ID of t, my oneLine(name of t), my oneLine(artist of t), my oneLine(album of t), ((round (duration of t)) as text), ((cloud status of t) as text), ((class of t) as text), discNo, trackNo, yr}
    set end of rows to my joinFields(row)
    end repeat
    end tell
    return my joinRecords(rows)
    end run
    """#)

    /// argv: persistent id, search text, kind. Plays exactly that track and waits until Music confirms it.
    static let playTrack = make("play_track", #"""
    on run argv
    set pid to item 1 of argv
    set q to item 2 of argv
    set kindName to item 3 of argv
    set target to missing value
    tell application "Music"
    if kindName is "song" then
    set res to search library playlist 1 for q only songs
    else if kindName is "album" then
    set res to search library playlist 1 for q only albums
    else if kindName is "artist" then
    set res to search library playlist 1 for q only artists
    else
    set res to search library playlist 1 for q
    end if
    if res is missing value then set res to {}
    repeat with t in res
    if (persistent ID of t) is pid then
    set target to contents of t
    exit repeat
    end if
    end repeat
    if target is missing value then error "NOT_FOUND|track" number 9001
    play target
    end tell
    repeat 60 times
    set row to my stateRow()
    set fields to my splitFields(row)
    if (item 1 of fields) is "playing" and (item 6 of fields) is pid then return row
    delay 0.1
    end repeat
    set row to my stateRow()
    error "NOT_PLAYING|" & row number 9005
    end run
    on splitFields(t)
    set AppleScript's text item delimiters to (character id 31)
    set parts to text items of t
    set AppleScript's text item delimiters to ""
    return parts
    end splitFields
    """#)

    /// argv: queue playlist name, search text, kind, shuffle (true|false), then the ordered persistent ids to queue.
    /// Rebuilds a dedicated playlist (never touching the library or other playlists) and plays it.
    static let playQueue = make("play_queue", #"""
    on run argv
    set queueName to item 1 of argv
    set q to item 2 of argv
    set kindName to item 3 of argv
    set wantShuffle to (item 4 of argv) is "true"
    set wanted to items 5 thru -1 of argv
    set found to {}
    set foundIds to {}
    tell application "Music"
    if kindName is "album" then
    set res to search library playlist 1 for q only albums
    else if kindName is "artist" then
    set res to search library playlist 1 for q only artists
    else if kindName is "song" then
    set res to search library playlist 1 for q only songs
    else
    set res to search library playlist 1 for q
    end if
    if res is missing value then set res to {}
    repeat with t in res
    set end of foundIds to (persistent ID of t)
    set end of found to (contents of t)
    end repeat
    end tell
    set ordered to {}
    repeat with wantedId in wanted
    set position_ to my indexOf((contents of wantedId), foundIds)
    if position_ > 0 then set end of ordered to (item position_ of found)
    end repeat
    if (count of ordered) is 0 then error "NOT_FOUND|queue" number 9001
    tell application "Music"
    try
    set existing to first user playlist whose name is queueName
    if (smart of existing) is false and (special kind of existing) is none then delete existing
    on error
    -- no previous queue
    end try
    set pl to make new user playlist with properties {name:queueName}
    repeat with t in ordered
    duplicate (contents of t) to pl
    end repeat
    set shuffle enabled to wantShuffle
    play pl
    end tell
    repeat 60 times
    set row to my stateRow()
    if row starts with "playing" then return row
    delay 0.1
    end repeat
    error "NOT_PLAYING|" & my stateRow() number 9005
    end run
    """#)

    /// argv: persistent id of a user playlist, shuffle (true|false).
    static let playPlaylist = make("play_playlist", #"""
    on run argv
    set pid to item 1 of argv
    set wantShuffle to (item 2 of argv) is "true"
    tell application "Music"
    try
    set pl to first user playlist whose persistent ID is pid
    on error
    error "NOT_FOUND|playlist" number 9001
    end try
    if (count of tracks of pl) is 0 then error "EMPTY|playlist" number 9006
    if wantShuffle then set shuffle enabled to true
    play pl
    end tell
    repeat 80 times
    set row to my stateRow()
    if row starts with "playing" then return row
    delay 0.1
    end repeat
    error "NOT_PLAYING|" & my stateRow() number 9005
    end run
    """#)

    /// Records of persistent id, name, kind ("none" for ordinary playlists), smart flag, track count, parent folder name.
    static let listPlaylists = make("list_playlists", #"""
    on run argv
    set rows to {}
    tell application "Music"
    set allLists to every user playlist
    repeat with pl in allLists
    set kindName to "none"
    set isSmart to "false"
    set trackCount to "0"
    set parentName to ""
    try
    set kindName to (special kind of pl) as text
    end try
    try
    set isSmart to (smart of pl) as text
    end try
    try
    set trackCount to (count of tracks of pl) as text
    end try
    try
    set parentName to my oneLine(name of parent of pl)
    end try
    set end of rows to my joinFields({persistent ID of pl, my oneLine(name of pl), kindName, isSmart, trackCount, parentName})
    end repeat
    end tell
    return my joinRecords(rows)
    end run
    """#)

    /// argv: action (pause|resume|stop|next|previous). Returns two records: the state before and after.
    static let transport = make("transport", #"""
    on run argv
    set action to item 1 of argv
    set beforeRow to my stateRow()
    tell application "Music"
    if action is "pause" then
    pause
    else if action is "resume" then
    play
    else if action is "stop" then
    stop
    else if action is "next" then
    next track
    else if action is "previous" then
    previous track
    else
    error "BAD_ACTION|" & action number 9003
    end if
    end tell
    set beforeFields to my splitFields(beforeRow)
    repeat 40 times
    set nowRow to my stateRow()
    set nowFields to my splitFields(nowRow)
    set currentState to item 1 of nowFields
    if action is "pause" and currentState is not "playing" then exit repeat
    if action is "stop" and currentState is "stopped" then exit repeat
    if action is "resume" and currentState is "playing" then exit repeat
    if (action is "next" or action is "previous") and currentState is "playing" and (item 6 of nowFields) is not (item 6 of beforeFields) then exit repeat
    delay 0.1
    end repeat
    return my joinRecords({beforeRow, my stateRow()})
    end run
    on splitFields(t)
    set AppleScript's text item delimiters to (character id 31)
    set parts to text items of t
    set AppleScript's text item delimiters to ""
    return parts
    end splitFields
    """#)

    /// argv: mode (level|delta), integer value. Returns the state after the change.
    static let volume = make("volume", #"""
    on run argv
    set mode to item 1 of argv
    set amount to (item 2 of argv) as integer
    tell application "Music"
    set current_ to sound volume
    if mode is "level" then
    set newVolume to amount
    else
    set newVolume to current_ + amount
    end if
    if newVolume < 0 then set newVolume to 0
    if newVolume > 100 then set newVolume to 100
    set sound volume to newVolume
    end tell
    return my stateRow()
    end run
    """#)

    static let all: [AppleScriptSource] = [state, search, playTrack, playQueue, playPlaylist, listPlaylists, transport, volume]
}
