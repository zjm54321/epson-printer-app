# Inputs: verbose ipptool output, then the fresh server-log slice for one submit.
# Only the first actual [Job N] tag identifies a message. Never accept PClose's
# unconditional success text or the separate Logging process as filter proof.
function fail(reason) {
    print "FAIL profile log: " reason > "/dev/stderr"
    failed = 1
    exit 1
}

# Undo one PAPPL 1.4 log.c string-escaping layer, only for quotes/backslashes.
# Control/octal/unknown escapes are not expected in our commands: fail closed.
# This is log decoding, not shell unescaping; words() still checks shell syntax.
function log_command(text,    i, c, decoded) {
    decoded = ""
    for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (c == "\\") {
            if (++i > length(text)) fail("truncated renderer log escape")
            c = substr(text, i, 1)
            if (c != "\\" && c != "\"" && c != "'")
                fail("unsupported renderer log escape")
        }
        decoded = decoded c
    }
    return decoded
}

# Tokenize, never execute, the single renderer command (including quoted args).
function words(text, result,    i, c, quote, word, active, n) {
    split("", result)
    quote = word = ""
    active = n = 0
    for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (quote != "") {
            if (c == quote) quote = ""
            else if (c == "\\" && quote == "\"") {
                if (++i > length(text)) return -1
                word = word substr(text, i, 1)
            } else word = word c
        } else if (c ~ /[ \t]/) {
            if (active) result[++n] = word
            word = ""
            active = 0
        } else if (c == "\"" || c == "'") {
            quote = c
            active = 1
        } else if (c == "\\") {
            if (++i > length(text)) return -1
            word = word substr(text, i, 1)
            active = 1
        } else {
            if (c ~ /[|;&<>]/) return -1
            word = word c
            active = 1
        }
    }
    if (quote != "") return -1
    if (active) result[++n] = word
    return n
}

BEGIN {
    if (expected_xy !~ /^(60x60|120x72|180x180|360x216)$/ || normalized == "")
        fail("invalid parser arguments")
    external = "cfFilterExternal (foomatic-rip): "
    renderer = external "Starting renderer with command: "
}

FILENAME == ARGV[1] {
    if ($0 ~ /^[ \t]*job-id[ \t]+\(integer\)[ \t]*=/) {
        value = $0
        sub(/^[ \t]*job-id[ \t]+\(integer\)[ \t]*=[ \t]*/, "", value)
        sub(/[ \t\r]+$/, "", value)
        if (value !~ /^[1-9][0-9]*$/ || (job_id != "" && value != job_id))
            fail("missing, invalid or ambiguous returned job-id")
        job_id = value
    }
    next
}

{
    if (job_id == "") fail("no returned job-id in ipptool output")
    if (!match($0, /\[Job [0-9]+\]/)) next
    if (substr($0, RSTART, RLENGTH) != "[Job " job_id "]") next
    message = substr($0, RSTART + RLENGTH)
    sub(/^[ \t]+/, "", message)
    sub(/[ \t\r]+$/, "", message)
    print message > normalized

    if (message ~ /^cfFilter/) {
        if (message ~ /(received|crashed on|terminated by|killed by|exited on|stopped by) signal/)
            fail("signal termination: " message)
        if (match(message, /(exited|stopped) with status -?[0-9]+/)) {
            status = substr(message, RSTART, RLENGTH)
            sub(/^.*status /, "", status)
            if (status + 0 != 0) fail("nonzero termination: " message)
        }
    }

    if (index(message, renderer) == 1) {
        if (++renderer_count != 1) fail("multiple renderer-start commands")
        command = log_command(substr(message, length(renderer) + 1))
        count = words(command, args)
        # PS/PWG logging quotes the complete command; PDF logging does not.
        if (count == 1) count = words(args[1], args)
        if (count < 1 || args[1] !~ /(^|\/)gs$/) fail("not a single GS renderer command")
        devices = resolutions = 0
        for (i = 2; i <= count; i++) {
            if (args[i] ~ /^-sDEVICE/) {
                devices++
                if (args[i] != "-sDEVICE=epson") fail("wrong renderer device")
            }
            if (args[i] ~ /^-r/) {
                resolutions++
                if (args[i] != "-r" expected_xy) fail("wrong renderer resolution")
            }
        }
        if (devices != 1 || resolutions != 1) fail("renderer device/resolution missing or duplicated")
    }
    if (message == external "renderer exited with status 0") renderer_ok++
    if (message == external "kid4 exited with status 0") kid4_ok++
    if (message ~ /^cfFilterExternal \(foomatic-rip\): Filter \(PID [1-9][0-9]*\) exited with no errors\.$/)
        filter_ok++

    if (message ~ /^cfFilterChain: .+ \(PID [1-9][0-9]*\) (started|exited with no errors)\.$/) {
        key = message
        sub(/^cfFilterChain: /, "", key)
        sub(/ (started|exited with no errors)\.$/, "", key)
        if (message ~ / started\.$/) {
            started[key]++
            stage = key
            sub(/ \(PID [1-9][0-9]*\)$/, "", stage)
            if (stage == "foomatic-rip") have_foomatic = 1
            if (stage == "Backend") have_backend = 1
        } else finished[key]++
    }
}

END {
    if (failed) exit 1
    if (job_id == "" || renderer_count != 1 || !renderer_ok || !kid4_ok || !filter_ok)
        fail("missing renderer/kid4/actual Filter success evidence")
    if (!have_foomatic || !have_backend) fail("foomatic-rip/Backend chain stages missing")
    for (key in started)
        if (started[key] != finished[key]) fail("unmatched chain start: " key)
    for (key in finished)
        if (started[key] != finished[key]) fail("unmatched chain exit: " key)
    close(normalized)
    print "PASS job " job_id ": one epson -r" expected_xy " renderer and all filter stages exited successfully"
}
