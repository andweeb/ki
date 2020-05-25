--- === File ===
---
--- File class that subclasses [Entity](Entity.html) to represent some directory or file to be automated
---
local Entity = require("entity")
local Cheatsheet = require("cheatsheet")
local File = Entity:subclass("File")
local spoonPath = hs.spoons.scriptPath()

--- File.behaviors
--- Variable
--- File [behaviors](Entity.html#behaviors) defined to invoke event handlers with the file path.
--- Currently supported behaviors:
--- * `default` - simply triggers the event handler with the instance's url string.
--- * `file` - triggers the appropriate event handler for the file entity instance. Depending on whether the workflow includes select mode, the event handler will be invoked with `shouldNavigate` set to `true`.
File.behaviors = Entity.behaviors + {
    default = function(self, eventHandler)
        eventHandler(self.path)
        return true
    end,
    file = function(self, eventHandler, _, _, workflow)
        local shouldNavigate = false

        for _, event in pairs(workflow) do
            if event.mode == "select" then
                shouldNavigate = true
                break
            end
        end

        eventHandler(self.path, shouldNavigate)

        return true
    end,
}

--- File:initialize(path, shortcuts)
--- Method
--- Initializes a new file instance with its path and custom shortcuts. By default, a cheatsheet and common shortcuts are initialized.
---
--- Parameters:
---  * `path` - The initial directory path
---  * `shortcuts` - The list of shortcuts containing keybindings and actions for the file entity
---  * `options` - A table containing various options that configures the file instance
---    * `showHiddenFiles` - A flag to display hidden files in the file selection modal. Defaults to `false`
---    * `sortAttribute` - The file attribute to sort the file selection list by. File attributes come from [hs.fs.dir](http://www.hammerspoon.org/docs/hs.fs.html#dir). Defaults to `modification` (last modified timestamp)
---
--- Each `shortcut` item should be a list with items at the following indices:
---  * `1` - An optional table containing zero or more of the following keyboard modifiers: `"cmd"`, `"alt"`, `"shift"`, `"ctrl"`, `"fn"`
---  * `2` - The name of a keyboard key. String representations of keys can be found in [`hs.keycodes.map`](https://www.hammerspoon.org/docs/hs.keycodes.html#map).
---  * `3` - The event handler that defines the action for when the shortcut is triggered
---  * `4` - A table containing the metadata for the shortcut, also a list with items at the following indices:
---    * `1` - The category name of the shortcut
---    * `2` - A description of what the shortcut does
---
--- Returns:
---  * None
function File:initialize(path, shortcuts, options)
    options = options or {}

    local absolutePath = hs.fs.pathToAbsolute(path)

    if not absolutePath then
        self.notifyError("Error initializing File entity", "Path "..path.." may not exist.")
        return
    end

    local success, value = pcall(function() return hs.fs.attributes(absolutePath) or {} end)

    if not success then
        self.notifyError("Error initializing File entity", value or "")
        return
    end

    local attributes = value
    local isDirectory = attributes.mode == "directory"
    local openFileInFolder = self:createEvent(path, "Open a file", function(...)
        self.open(...)
    end)

    local actions = {
        openFileInFolder = openFileInFolder,
        openFileInFolderWith = self:createEvent(path, "Open file with application", function(target)
            self:openWith(target)
        end),
        showInfoForFileInFolder = self:createEvent(path, "Show info for file", function(target)
            self:openInfoWindow(target)
        end),
        quickLookFileInFolder = self:createEvent(path, "View file with QuickLook", function(target)
            hs.execute("qlmanage -p "..target)
        end),
        deleteFileInFolder = self:createEvent(path, "Move file to trash", function(target)
            self:moveToTrash(target)
        end),
        open = function(target, shouldNavigate)
            if shouldNavigate then
                return openFileInFolder(target)
            end

            return self.open(target)
        end,
    }
    local commonShortcuts = {
        { nil, nil, actions.open, { path, "Activate/Focus" } },
        { { "shift" }, "/", function(...) self:showCheatsheet(...) end, { path, "Show Cheatsheet" } },
    }

    -- Append directory shortcuts if the file entity is representing a directory path
    if isDirectory then
        local commonDirectoryShortcuts = {
            { nil, "c", function(...) self:copy(...) end, { path, "Copy File to Folder" } },
            { nil, "d", actions.deleteFileInFolder, { path, "Move File in Folder to Trash" } },
            { nil, "i", actions.showInfoForFileInFolder, { path, "Open File Info Window" } },
            { nil, "m", function(...) self:move(...) end, { path, "Move File to Folder" } },
            { nil, "o", openFileInFolder, { path, "Open File in Folder" } },
            { nil, "space", actions.quickLookFileInFolder, { path, "Quick Look" } },
            { { "shift" }, "o", actions.openFileInFolderWith, { path, "Open File in Folder with App" } },
        }

        for _, shortcut in pairs(commonDirectoryShortcuts) do
            table.insert(commonShortcuts, shortcut)
        end
    end

    self.name = path
    self.path = path
    self.showHiddenFiles = options.showHiddenFiles or false
    self.sortAttribute = options.sortAttribute or "modification"

    self:registerShortcuts(self:mergeShortcuts(shortcuts, commonShortcuts))

    local cheatsheetDescription = "Ki shortcut keybindings registered for file "..self.path
    self.cheatsheet = Cheatsheet:new(self.path, cheatsheetDescription, self.shortcuts)
end

-- Show cheatsheet action
function File:showCheatsheet(path)
    local iconURI = nil
    local fileIcon = self.getFileIcon(path)
    if fileIcon then
        iconURI = fileIcon:encodeAsURLString()
    end

    self.cheatsheet:show(iconURI)
end

--- File:createEvent(path, placeholderText, handler) -> function
--- Method
--- Convenience method to create file events that share the similar behavior of allowing navigation before item selection
---
--- Parameters:
---  * `path` - The path of a file
---  * `placeholderText` - Text to display as a placeholder in the selection modal
---  * `handler` - the selection event handler function that takes in the following arguments:
---     * `path` - the selected target path
---
--- Returns:
---   * An event handler function
function File:createEvent(path, placeholderText, handler)
    return function()
        self:navigate(path, placeholderText, handler)
    end
end

--- File:runApplescriptAction(viewModel)
--- Method
--- Convenience method to render and run the `file.applescript` file and notify on execution errors. Refer to the applescript template file itself to see available view model records.
---
--- Parameters:
---  * `viewModel` - The view model object used to render the template
---
--- Returns:
---   * None
function File:runApplescriptAction(viewModel)
    local script = self.renderScriptTemplate("file", viewModel)
    local isOk, _, rawTable = hs.osascript.applescript(script)

    if not isOk then
        local actionName = viewModel and "\""..viewModel.action.."\"" or "unknown"
        local errorMessage = "Error executing the "..actionName.." file action"
        self.notifyError(errorMessage, rawTable.NSLocalizedFailureReason)
    end
end

--- File:getFileName(path) -> string
--- Method
--- Extracts a filename from a file path
---
--- Parameters:
---  * `path` - The path of a file
---
--- Returns:
---   * The filename or nil
function File.getFileName(path)
    if not path then return end

    return path:match("^.+/(.+)$")
end


--- File:getFileIcon(path) -> [`hs.image`](http://www.hammerspoon.org/docs/hs.image.html)
--- Method
--- Retrieves an icon image for the given file path or returns `nil` if not found
---
--- Parameters:
---  * `path` - The path of a file
---
--- Returns:
---   * The file icon [`hs.image`](http://www.hammerspoon.org/docs/hs.image.html) object
function File.getFileIcon(path)
    if not path then return end

    local bundleInfo = hs.application.infoForBundlePath(path)

    if bundleInfo and bundleInfo.CFBundleIdentifier then
        return hs.image.imageFromAppBundle(bundleInfo.CFBundleIdentifier)
    end

    local fileUTI = hs.fs.fileUTI(path)
    local fileImage = hs.image.iconForFileType(fileUTI)

    return fileImage
end

--- File:navigate(path, placeholderText, handler)
--- Method
--- Recursively navigates through parent and child directories until a selection is made
---
--- Parameters:
---  * `path` - the path of the target file
---  * `placeholderText` - Text to display as a placeholder in the selection modal
---  * `handler` - the selection callback handler function invoked with the following arguments:
---    * `targetFilePath` - the target path of the selected file
---
--- Returns:
---   * None
function File:navigate(path, placeholderText, handler)
    local absolutePath = hs.fs.pathToAbsolute(path)
    local function onSelection(targetPath, shouldTriggerAction)
        local attributes = hs.fs.attributes(targetPath)

        if attributes.mode == "directory" and not shouldTriggerAction then
            self:navigate(targetPath, placeholderText, handler)
        else
            handler(targetPath)
        end
    end

    -- Defer execution to avoid conflicts with the selection modal that just previously closed
    hs.timer.doAfter(0, function()
        self:showFileSelectionModal(absolutePath, onSelection, {
            placeholderText = placeholderText,
        })
    end)
end

--- File:showFileSelectionModal(path, handler[, options]) -> [choice](https://www.hammerspoon.org/docs/hs.chooser.html#choices) object list
--- Method
--- Shows a selection modal with a list of files at a given path.
---
--- Parameters:
---  * `path` - the path of the directory that should have its file contents listed in the selection modal
---  * `handler` - the selection event handler function that takes in the following arguments:
---     * `targetPath` - the selected target path
---     * `shouldTriggerAction` - a boolean value to ensure the action is triggered
---  * `options` - A table containing various options to configure the underlying [`hs.chooser`](https://www.hammerspoon.org/docs/hs.chooser.html) instance
---
--- Returns:
---   * A list of [choice](https://www.hammerspoon.org/docs/hs.chooser.html#choices) objects
function File:showFileSelectionModal(path, handler, options)
    local choices = {}
    local parentPathRegex = "^(.+)/.+$"
    local absolutePath = hs.fs.pathToAbsolute(path)
    local parentDirectory = absolutePath:match(parentPathRegex) or "/"

    -- Add selection modal shortcut to open files with cmd + return
    local function openFile(modal)
        local selectedRow = modal:selectedRow()
        local choice = modal:selectedRowContents(selectedRow)
        handler(choice.filePath, true)
        modal:cancel()
    end
    -- Add selection modal shortcut to toggle hidden files cmd + shift + "."
    local function toggleHiddenFiles(modal)
        modal:cancel()
        self.showHiddenFiles = not self.showHiddenFiles

        -- Defer execution to avoid conflicts with the prior selection modal that just closed
        hs.timer.doAfter(0, function()
            self:showFileSelectionModal(path, handler, options)
        end)
    end
    local navigationShortcuts = {
        { { "cmd" }, "return", openFile },
        { { "cmd", "shift" }, ".", toggleHiddenFiles },
    }
    self.selectionModalShortcuts = self:mergeShortcuts(navigationShortcuts, self.selectionModalShortcuts)

    local iterator, directory = hs.fs.dir(absolutePath)
    if iterator == nil then
        self.notifyError("Error walking the path at "..path)
        return
    end

    for file in iterator, directory do
        local filePath = absolutePath.."/"..file
        local attributes = hs.fs.attributes(filePath) or {}
        local displayName = hs.fs.displayName(filePath) or file
        local isHiddenFile = string.sub(file, 1, 1) == "."
        local shouldShowFile = isHiddenFile and self.showHiddenFiles or not isHiddenFile
        local subText = filePath

        if file ~= "." and file ~= ".." and shouldShowFile then
            table.insert(choices, {
                text = displayName,
                subText = subText,
                file = file,
                filePath = filePath,
                image = filePath and self.getFileIcon(filePath),
                fileAttributes = attributes,
            })
        end
    end

    -- Sort choices by last modified timestamp and add current/parent directories to choices
    table.sort(choices, function(a, b)
        local value1 = a.fileAttributes[self.sortAttribute]
        local value2 = b.fileAttributes[self.sortAttribute]
        return value1 > value2
    end)
    table.insert(choices, {
        text = "..",
        subText = parentDirectory.." (Parent directory)",
        file = "..",
        filePath = parentDirectory,
        image = self.getFileIcon(absolutePath),
    })
    table.insert(choices, {
        text = ".",
        subText = absolutePath.." (Current directory)",
        file = ".",
        filePath = absolutePath,
        image = self.getFileIcon(absolutePath),
    })

    local function onSelection(choice)
        if choice then
            handler(choice.filePath)
        end
    end

    self:showSelectionModal(choices, onSelection, options)
end

--- File:open(path)
--- Method
--- Opens a file or directory at the given path
---
--- Parameters:
---  * `path` - the path of the target file to open
---
--- Returns:
---   * None
function File.open(path)
    if not path then return nil end

    local absolutePath = hs.fs.pathToAbsolute(path)
    local attributes = hs.fs.attributes(absolutePath) or {}
    local isDirectory = attributes.mode == "directory"

    hs.open(absolutePath)

    if isDirectory then
        hs.application.open("Finder")
    end
end

--- File.createFileChoices(fileListIterator, createText, createSubText) -> choice object list
--- Method
--- Creates a list of choice objects each representing the file walked with the provided iterator
---
--- Parameters:
---  * `fileListIterator` - an iterator to walk a list of file paths, i.e. `s:gmatch(pattern)`
---  * `createText` - an optional function that takes in a single `path` argument to return a formatted string to assign to the `text` field in each file choice object
---  * `createSubText` - an optional function that takes in a single `path` argument to return a formatted string to assign to the `subText` field in each file choice object
---
--- Returns:
---   * `choices` - A list of choice objects each containing the following fields:
---     * `text` - The primary chooser text string
---     * `subText` - The chooser subtext string
---     * `fileName` - The name of the file
---     * `path` - The path of the file
function File.createFileChoices(fileListIterator, createText, createSubText)
    local choices = {}
    local fileNameRegex = "^.+/(.+)$"

    for path in fileListIterator do
        local bundleInfo = hs.application.infoForBundlePath(path)
        local fileName = path:match(fileNameRegex) or ""
        local choice = {
            text = createText and createText(path) or fileName,
            subText = createSubText and createSubText(path) or path,
            fileName = fileName,
            path = path,
        }

        if bundleInfo then
            choice.text = bundleInfo.CFBundleName
            choice.image = hs.image.imageFromAppBundle(bundleInfo.CFBundleIdentifier)
        end

        table.insert(choices, choice)
    end

    return choices
end

--- File:openWith(path)
--- Method
--- Opens a file or directory at the given path with a specified application and raises the application to the front
---
--- Parameters:
---  * `path` - the path of the target file to open
---
--- Returns:
---   * None
function File:openWith(path)
    local allApplicationsPath = spoonPath.."/bin/AllApplications"
    local shellscript = allApplicationsPath.." -path \""..path.."\""
    local output = hs.execute(shellscript)
    local choices = self.createFileChoices(string.gmatch(output, "[^\n]+"))

    local function onSelection(choice)
        if not choice then return end

        self:runApplescriptAction({
            action = "open-with",
            filePath1 = path,
            filePath2 = choice.path,
        })
    end

    -- Defer execution to avoid conflicts with the prior selection modal that just closed
    hs.timer.doAfter(0, function()
        self:showSelectionModal(choices, onSelection, {
            placeholderText = "Open with application",
        })
    end)
end

--- File:openInfoWindow(path)
--- Method
--- Opens a Finder information window for the file at `path`
---
--- Parameters:
---  * `path` - the path of the target file
---
--- Returns:
---   * None
function File:openInfoWindow(path)
    self:runApplescriptAction({ action = "open-info-window", filePath1 = path })
end

--- File:moveToTrash(path)
--- Method
--- Moves a file or directory at the given path to the Trash. A dialog block alert opens to confirm before proceeding with the action.
---
--- Parameters:
---  * `path` - the path of the target file to move to the trash
---
--- Returns:
---   * None
function File:moveToTrash(path)
    local filename = self.getFileName(path)
    local question = "Move \""..filename.."\" to the Trash?"
    local details = "New file location:\n".."~/.Trash/"..filename

    self.triggerAfterConfirmation(question, details, function()
        self:runApplescriptAction({ action = "move-to-trash", filePath1 = path })
    end)
end

--- File:move(path)
--- Method
--- Method to move one file into a directory. Opens a navigation modal for selecting the target file, then on selection opens another navigation modal to select the destination path. A confirmation dialog is presented to proceed with moving the file to the target directory.
---
--- Parameters:
---  * `path` - the initial directory path to select a target file to move from
---
--- Returns:
---   * None
function File:move(initialPath)
    self:navigate(initialPath, "Select file to be moved", function(targetPath)
        self:navigate(initialPath, "Select destination folder", function(destinationPath)
            local targetFile = self.getFileName(targetPath)
            local destinationFile = self.getFileName(destinationPath)
            local question = "Move \""..targetFile.."\" to \""..destinationFile.."\"?"
            local details = "New file location:\n"..destinationPath.."/"..targetFile

            self.triggerAfterConfirmation(question, details, function()
                self:runApplescriptAction({
                    action = "move",
                    filePath1 = targetPath,
                    filePath2 = destinationPath,
                })
            end)
        end)
    end)
end

--- File:copy(path)
--- Method
--- Method to copy one file into a directory. Opens a navigation modal for selecting the target file, then on selection opens another navigation modal to select the destination path. A confirmation dialog is presented to proceed with copying the file to the target directory.
---
--- Parameters:
---  * `path` - the initial directory path to select a target file to copy
---
--- Returns:
---   * None
function File:copy(initialPath)
    self:navigate(initialPath, "Select file to be copied", function(targetPath)
        self:navigate(initialPath, "Select destination folder", function(destinationPath)
            local targetFile = self.getFileName(targetPath)
            local destinationFile = self.getFileName(destinationPath)
            local question = "Copy \""..targetFile.."\" to \""..destinationFile.."\"?"
            local details = "New file location:\n"..destinationPath.."/"..targetFile

            self.triggerAfterConfirmation(question, details, function()
                self:runApplescriptAction({
                    action = "copy",
                    filePath1 = targetPath,
                    filePath2 = destinationPath,
                })
            end)
        end)
    end)
end

return File
