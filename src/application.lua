--- === Application ===
---
--- Application class that subclasses [Entity](Entity.html) to represent some automatable desktop application
---

local Util = require("util")
local Entity = require("entity")
local ApplicationWatcher = require("application-watcher")

local Application = Entity:subclass("Application")
local Behaviors = {}

-- Application behavior function for entity mode
function Behaviors.entity(self, eventHandler, _, _, workflow)
    -- Determine whether the workflow includes select mode
    local shouldSelect = false
    for _, event in pairs(workflow) do
        if event.mode == "select" then
            shouldSelect = true
            break
        end
    end

    -- Execute the select behavior if the workflow includes select mode
    if shouldSelect then
        return Behaviors.select(self, eventHandler)
    end

    -- Create local action execution function to either defer or immediately invoke
    local function executeAction(appInstance)
        local _, autoExit = eventHandler(appInstance, shouldSelect)
        return autoExit == nil and self.autoExitMode or autoExit
    end

    return Behaviors.dispatchAction(self, executeAction)
end

-- Application behavior function for select mode
function Behaviors.select(self, eventHandler)
    -- Create local action execution function to either defer or immediately invoke
    local function executeAction(appInstance)
        local choices = self:getSelectionItems()

        if choices and #choices > 0 then
            self:showSelectionModal(choices, function (choice)
                if choice then
                    eventHandler(appInstance, choice)
                end
            end)
        end
    end

    return Behaviors.dispatchAction(self, executeAction)
end

-- Use the entity mode behavior as the default behavior
Behaviors.default = Behaviors.entity

-- Dispatch action behavior for application entities to defer action execution after launch
function Behaviors.dispatchAction(self, action)
    local appState = ApplicationWatcher.states[self.name]
    local app = self:getApplication()
    local status = nil

    if appState then
        app = appState.app
        status = appState.status
    end

    -- Determine whether the application is currently open
    local isActivated = status == ApplicationWatcher.statusTypes.activated
    local isLaunched = status == ApplicationWatcher.statusTypes.launched
    local isUnhidden = status == ApplicationWatcher.statusTypes.unhidden
    local isApplicationOpen = isActivated or isLaunched or isUnhidden

    -- Execute the action if the application is already running
    if app and app:isRunning() or isApplicationOpen then
        return action(app)
    end

    -- Determine the target event based on the current application status
    local targetEvent = ApplicationWatcher.statusTypes.launched
    if status == ApplicationWatcher.statusTypes.deactivated then
        targetEvent = ApplicationWatcher.statusTypes.activated
    elseif status == ApplicationWatcher.statusTypes.hidden then
        targetEvent = ApplicationWatcher.statusTypes.unhidden
    end

    -- Defer the action execution to until the application has opened
    ApplicationWatcher:registerEventCallback(self.name, targetEvent, action)

    -- Launch the application
    hs.application.open(self.name)

    return self.autoExitMode
end

--- Application.behaviors
--- Variable
--- Application [behaviors](Entity.html#behaviors) defined to invoke event handlers with `hs.application`.
Application.behaviors = Entity.behaviors + Behaviors

--- Application:getSelectionItems()
--- Method
--- Default implementation of [`Entity:getSelectionItems()`](Entity.html#getSelectionItems) to returns choice objects containing application window information.
---
--- This can be overridden for instances to return selection items particular for specific Application entities, i.e. override this function to return conversation choices for the Messages instance.
---
--- Parameters:
---  * None
---
--- Returns:
---   * A list of [choice](https://www.hammerspoon.org/docs/hs.chooser.html#choices) objects
function Application:getSelectionItems()
    local app = self:getApplication()
    local windows = app:allWindows()
    local choices = {}

    for index, window in pairs(windows) do
        local state = window:isFullScreen() and "(full screen)"
            or window:isMinimized() and "(minimized)"
            or ""

        table.insert(choices, {
            text = window:title(),
            subText = "Window "..index.." "..state,
            windowId = window:id(),
            windowIndex = index,
        })
    end

    return choices
end

--- Application.createMenuItemEvent(menuItem[, shouldFocusAfter, shouldFocusBefore])
--- Method
--- Convenience method to create an event handler that selects a menu item, with optionally specified behavior on how the menu item selection occurs
---
--- Parameters:
---  * `menuItem` - the menu item to select, specified as either a string or a table
---  * `options` - a optional table containing some or all of the following fields to define the behavior for the menu item selection event:
---     * `isRegex` - a boolean denoting whether there is a regular expression within the menu item name(s)
---     * `isToggleable` - a boolean denoting whether the menu item parameter is passed in as a list of two items to toggle between, i.e., `{ "Play", "Pause" }`
---     * `focusBefore` - an optional boolean denoting whether to focus the application before the menu item is selected
---     * `focusAfter` - an optional boolean denoting whether to focus the application after the menu item is selected
---
--- Returns:
---  * None
function Application.createMenuItemEvent(menuItem, options)
    options = options or {}

    return function(app, choice)
        if (options.focusBefore) then
            Application.focus(app, choice)
        end

        if options.isToggleable then
            _ = app:selectMenuItem(menuItem[1], options.isRegex)
                or app:selectMenuItem(menuItem[2], options.isRegex)
        else
            app:selectMenuItem(menuItem, options.isRegex)
        end

        if (options.focusAfter) then
            Application.focus(app, choice)
        end
    end
end

--- Application.createMenuItemSelectionEvent(menuItem[, shouldFocusAfter, shouldFocusBefore])
--- Method
--- Convenience method to create an event handler that presents a selection modal containing menu items that are nested/expandable underneath at the provided `menuItem` path, with optionally specified behavior on how the menu item selection occurs
---
--- Parameters:
---  * `menuItem` - a table list of strings that represent a path to a menu item that expands to menu item list, i.e., `{ "File", "Open Recent" }`
---  * `options` - a optional table containing some or all of the following fields to define the behavior for the menu item selection event:
---     * `focusBefore` - an optional boolean denoting whether to focus the application before the menu item is selected
---     * `focusAfter` - an optional boolean denoting whether to focus the application after the menu item is selected
---
--- Returns:
---  * None
function Application.createMenuItemSelectionEvent(menuItem, options)
    options = options or {}

    return function(app, windowChoice)
        local menuItemList = Application.getMenuItemList(app, menuItem)
        local choices = {}

        for _, item in pairs(menuItemList) do
            if item.AXTitle and #item.AXTitle > 0 then
                table.insert(choices, {
                    text = item.AXTitle,
                })
            end
        end

        Application:showSelectionModal(choices, function(menuItemChoice)
            if menuItemChoice then
                if (options.focusBefore) then
                    Application.focus(app, windowChoice)
                end

                local targetMenuItem = Util:clone(menuItem)

                table.insert(targetMenuItem, menuItemChoice.text)

                app:selectMenuItem(targetMenuItem)

                if (options.focusAfter) then
                    Application.focus(app, windowChoice)
                end
            end
        end)
    end
end

--- Application.getMenuItemList(app, menuItemPath) -> table or nil
--- Method
--- Gets a list of menu items from a hierarchical menu item path
---
--- Parameters:
---  * `app` - The target [`hs.application`](https://www.hammerspoon.org/docs/hs.application.html) object
---  * `menuItemPath` - A table representing the hierarchical path of the target menu item (e.g. `{ "File", "Share" }`)
---
--- Returns:
---   * A list of [menu items](https://www.hammerspoon.org/docs/hs.application.html#getMenuItems) or `nil`
function Application.getMenuItemList(app, menuItemPath)
    local menuItems = app:getMenuItems()
    local isFound = false

    for _, menuItemName in pairs(menuItemPath) do
        for _, menuItem in pairs(menuItems) do
            if menuItem.AXTitle == menuItemName then
                menuItems = menuItem.AXChildren[1]
                if menuItemName ~= menuItemPath[#menuItemPath] then
                    isFound = true
                end
            end
        end
    end

    return isFound and menuItems or nil
end

--- Application:initialize(name, shortcuts, autoExitMode)
--- Method
--- Initializes a new application instance with its name and shortcuts. By default, common shortcuts are automatically registered, and the initialized [entity](Entity.html) defaults, such as the cheatsheet.
---
--- Parameters:
---  * `name` - The entity name
---  * `shortcuts` - The list of shortcuts containing keybindings and actions for the entity
---  * `autoExitMode` - A boolean denoting to whether enable or disable automatic mode exit after the action has been dispatched
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
function Application:initialize(name, shortcuts, autoExitMode)
    local commonShortcuts = {
        { nil, nil, self.focus, { name, "Activate/Focus" } },
        { nil, "a", self.createMenuItemEvent("About "..name), { name, "About "..name } },
        { nil, "f", self.toggleFullScreen, { "View", "Toggle Full Screen" } },
        { nil, "h", self.createMenuItemEvent("Hide "..name), { name, "Hide Application" } },
        { nil, "q", self.createMenuItemEvent("Quit "..name), { name, "Quit Application" } },
        { nil, ",", self.createMenuItemEvent("Preferences...", true), { name, "Open Preferences" } },
    }

    local mergedShortcuts = self.mergeShortcuts(shortcuts, commonShortcuts)

    Entity.initialize(self, name, mergedShortcuts, autoExitMode)
end

--- Application:getApplication() -> hs.application object or nil
--- Method
--- Gets the [`hs.application`](https://www.hammerspoon.org/docs/hs.application.html) object from the instance name
---
--- Parameters:
---  * None
---
--- Returns:
---   * An `hs.application` object or `nil` if the application could not be found
function Application:getApplication()
    return hs.application.get(self.name)
end

--- Application:focus(app[, choice])
--- Method
--- Activates an application or focuses a specific application window or tab
---
--- Parameters:
---  * `app` - the [`hs.application`](https://www.hammerspoon.org/docs/hs.application.html) object
---  * `choice` - an optional [choice](https://www.hammerspoon.org/docs/hs.chooser.html#choices) object, each with a `windowId` field and (optional) `tabIndex` field
---
--- Returns:
---   * None
function Application.focus(app, choice)
    if choice then
        local window = hs.window(tonumber(choice.windowId))

        if window then window:focus() end
        if window and choice.tabIndex then
            window:focusTab(choice.tabIndex)
        end
    elseif app then
        app:activate()
    end
end

--- Application:toggleFullScreen(app)
--- Method
--- Toggles the full screen state of the focused application window
---
--- Parameters:
---  * `app` - the [`hs.application`](https://www.hammerspoon.org/docs/hs.application.html) object
---
--- Returns:
---   * `true`
function Application.toggleFullScreen(app)
    app:focusedWindow():toggleFullScreen()
    return true
end

return Application
