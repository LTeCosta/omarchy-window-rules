-- Loader block for io.github.ltecosta.window-rules.
--
-- Append this block at the end of ~/.config/hypr/hyprland.lua, after Omarchy's
-- defaults and any hand-written window rules, so your plugin rules take
-- precedence (Hyprland evaluates window rules top to bottom and the last
-- matching rule wins).
--
-- If the plugin is not installed, io.open returns nil and this block does
-- nothing. Reload Hyprland with `hyprctl reload` after editing.
--
-- Optional key bindings (for ~/.config/hypr/bindings.lua or hyprland.lua):
--   o.bind("SUPER + ALT + W", "Save window rule", "omarchy-shell io.github.ltecosta.window-rules capture")
--   o.bind("SUPER + SHIFT + ALT + W", "Window rules", { panel = "io.github.ltecosta.window-rules" })

do
  local home = os.getenv("HOME") or ""
  local config = os.getenv("XDG_CONFIG_HOME")
  if not config or config:sub(1, 1) ~= "/" then config = home .. "/.config" end
  local path = config .. "/omarchy/plugins/io.github.ltecosta.window-rules/hypr/window-rules.lua"
  local file = io.open(path, "r")
  if file then
    file:close()
    local ok, window_rules = pcall(dofile, path)
    if ok and type(window_rules) == "table" then
      -- Sample resolver: send windows to a workspace slot on the first
      -- non-mirrored external monitor, falling back to the built-in display
      -- (or the active monitor) when no external display is connected.
      -- Remove or replace this call if you do not use resolver targets.
      local function is_internal(monitor)
        return monitor.name:match("^eDP")
          or monitor.name:match("^LVDS")
          or monitor.name:match("^DSI")
      end

      window_rules.register_resolver("external-slot", {
        label = "External display slot",
        arg_label = "Slot",
        resolve = function(slot, _window)
          local max_slots = (o and o.workspaces and o.workspaces.slots) or 10
          if type(slot) ~= "number" or math.tointeger(slot) == nil or slot < 1 or slot > max_slots then
            return nil
          end

          local external = nil
          local fallback = nil

          for _, monitor in ipairs(hl.get_monitors()) do
            if not monitor.is_mirror then
              if not is_internal(monitor) and not external then
                external = monitor
              elseif not fallback then
                fallback = monitor
              end
            end
          end

          local target = external or fallback or hl.get_active_monitor()
          if target then
            return {
              workspace = o.workspaces.workspace_id(target, slot),
              monitor = target.name,
            }
          end
          return { workspace = slot }
        end,
      })

      window_rules.load()
    end
  end
end
