-- AppleScript template for various QuickTime Player actions
-- `action` - the name of the action
-- `targetDocument` - the target QuickTime Player document
set action to "{{action}}"

tell application "QuickTime Player"

    set target to {{target}}

	if action is "toggle-play" then

        if target is playing then

            pause target

        else

            play target

        end if

    else if action is "stop" then

        stop target

    else if action is "toggle-looping" then

        if the first document is looping then

            set looping of target to false

        else

            set looping of target to true

        end if

        return looping of target

	end if

end tell
