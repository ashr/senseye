--
-- Support that relies on composition surface to
-- implement simple chainable popup menus
--

--
-- popup drawing (ctrlh_wnd.lua)
--
local menu_border_color = {140, 140, 140};
local menu_bg_color = {80, 80, 80};

local function popup_destroy(wm, popup, cascade)
-- need to track this so we can re-focus the right window on
-- a deleted cascade
	local lp = popup.previous;
	mouse_droplistener(popup.capt_mh);
	local p = popup.parent;

-- recursively drop mouse handlers
	while (p and cascade) do
		if (p.capt_mh) then
			mouse_droplistener(p.capt_mh);
			p.capt_mh = nil;
		end

		if (p.previous) then
			lp = p.previous;
		end

		p = p.parent;
	end

	if (not p) then
		wm:lock_input();
	end

	popup:destroy(cascade);
	if (lp and lp.select) then
		lp:select();
	end
	return p;
end

local function menu_input(wm, popup, iv, cascade)
	if (type(iv) == "table") then
	else
		if (iv == "UP") then
			popup:step(-1);
		elseif (iv == "DOWN") then
			popup:step(1);
		elseif (iv == "RIGHT") then
			popup.click(true);
		elseif (iv == "ESCAPE" or iv == "LEFT") then
			popup_destroy(wm, popup, iv == "ESCAPE");
		end
	end
end

--
-- Combine and validate the menus supplied in m1 with m2.
-- m2 can override and cancel out menus in m1.
--
function merge_menu(m1, m2)
	local res = {};

-- shallow mapping
	for k,v in ipairs(m1) do
		table.insert(res, v);
	end

-- projection
	for k, v in ipairs(m2) do
		local found = false;
		for j,m in ipairs(res) do
			if (m.label == v.label) then
				res[j] = v;
				found = true;
				break;
			end
		end

		if (not found) then
			table.insert(res, v);
		end
	end

-- filter out "broken"
	local i = 1;
	while i <= #res do
		if (res[i].submenu == nil and
			res[i].value == nil and res[i].handler == nil) then
			table.remove(res, i);
		else
			i = i + 1;
		end
	end

	return res;
end

function popup_inactivate(wnd)
	local cover = fill_surface(wnd.width, wnd.height, 0, 0, 0);
	link_image(cover, wnd.anchor);
	image_inherit_order(cover, true);
	order_image(cover, 3);
	blend_image(cover, 0.5, 5);
	wnd.popup_cover = cover;
end

function popup_activate(wnd)
	if (valid_vid(wnd.popup_cover)) then
		instant_image_transform(wnd.popup_cover);
		expire_image(wnd.popup_cover, 5);
		blend_image(wnd.popup_cover, 0.0, 5);
	end
end

function spawn_popupmenu(wm, menu_in, target, cursorpos)
	local list = {
		menu_text_fontstr
	};

	if (menu_in == nil) then
		return;
	end

	if (target == nil) then
		target = wm.selected;
	end

	local menutbl = {};
	for i, v in ipairs(menu_in) do
		if (not v.eval or v.eval(target)) then
			table.insert(menutbl, v);
		end
	end

	for k, v in ipairs(menutbl) do
		table.insert(list, v.label);
		if (k < #menutbl) then
			table.insert(list, [[\r\n]]);
		end
	end

-- draw the labels, create a background surface and link the labels to that,
-- make sure that mouse events are captured by the canvas and the drawing order
-- is correct.
	local text, lines = render_text(list);
	local props = image_surface_properties(text);
	local canvas = fill_surface(props.width + 10, props.height + 10,
			menu_bg_color[1], menu_bg_color[2], menu_bg_color[3]);

	show_image({canvas, text});
	move_image(text, 0, 5);
	link_image(text, canvas);
	image_inherit_order(text, 1);
	image_mask_set(text, MASK_UNPICKABLE);

-- add a cursor that indicates the currently selected item
	local cursor = color_surface(props.width + 10,
		lines[2] and lines[2] or 1, 255, 255, 255);

	blend_image(cursor, 0.5);
	force_image_blend(cursor, BLEND_MULTIPLY);
	link_image(cursor, text);
	image_mask_set(cursor, MASK_UNPICKABLE);
	image_inherit_order(cursor, 1);
	if (#menutbl == 1) then
		hide_image(cursor);
	end

-- setup the popup, focus it, add a border and position close to either
-- the mouse cursor or the previous window
	local popup = wm:add_window(canvas, {});
	popup.flag_popup = true;
	popup.cursor = cursor;
	popup.previous = wm.selected;
	popup:select();
	popup.noblend = true;
	popup.inactivate = popup_inactivate;
	popup.activate = popup_activate;
	popup.name = popup.name .. "_popup";

	popup:resize(props.width + 10, props.height);
	popup:set_border(1, menu_border_color);
	if (not cursorpos or not prev) then
		local x, y = mouse_xy();
		popup:move(x - 5, y - 5, true); -- true makes sure we don't flow outside win
	else
		local px, py = prev:abs_xy(prev.x, prev.y);
		local px = px + math.ceil(prev.width * 0.5 - 0.5); --- 5; -- + prev.borderw + 2;
		py = py + image_surface_properties(prev.cursor).y + 5;
		popup:move(px, py, true);
	end

-- we set this to cascade destroy when an item is selected
	if (prev and prev.flag_popup) then
		popup.parent = prev;
	end

	local index = 1;
	popup.click = function(cpop, rv)
		if (menutbl[index].handler) then
			menutbl[index].handler(target, rv);
			popup_destroy(wm, popup, true);

		elseif (menutbl[index].submenu) then
			local mnu = menutbl[index].submenu;
			if (type(mnu) == "function") then
				mnu = mnu(target);
			elseif (#mnu == 0) then
				return;
			end

			popup:inactivate();
			local pm = spawn_popupmenu(wm, mnu, target, cpop);

		elseif (menutbl[index].value) then
			menutbl.handler(target, menutbl[index].value, rv);
			popup_destroy(wm, popup, true);
		end
	end

	popup.rclick = function(cpop)
		cpop.click(cpop, true);
	end

	popup.step = function(p, ns)
		index = index + (ns ~= 0 and ((ns > 0 and 1 or -1)) or 0);
		if (index <= 0) then
			index = #lines;
		elseif (index > #lines) then
			index = 1;
		end
		move_image(cursor, 0, lines[index] - 5);
	end

-- make sure that the selected line follows the cursor
	popup.motion = function(wnd, vid, x, y)
		x = x - wnd.x;
		y = y - wnd.y;
		index = 1;

		while (index <= #lines-1) do
			if (y >= lines[index] and y <= lines[index + 1]) then
				break;
			end
			index = index + 1;
		end

		move_image(cursor, 0, lines[index] - 5);
	end

-- locking input will prevent other actions from having effect
	wm:lock_input(function(inp)
		menu_input(wm, wm.selected, inp); end );

-- and a "capture all" surface for preventing other objects
-- from receiving mouse events
	local capt = null_surface(wm.max_w, wm.max_h);
	link_image(capt, popup.canvas);
	image_mask_clear(capt, MASK_POSITION);
	image_inherit_order(capt, 1);
	order_image(capt, -1);
	show_image(capt);

-- cheat with order to have submenus and captures work correctly
	order_image(popup.anchor, wm:max_order());

	local mh = {
		name = "capture_mh",
		capture = capt,
		press = function(vid)
			mouse_state().click_cnt = 0;
			popup_destroy(wm, popup, true);
		end,
		own = function(wnd, vid)
			return vid == wnd.capture;
		end
	};

	popup:step(0);
	popup.capt_mh = mh;
	mouse_addlistener(mh, {"press", "rclick"});
	return popup;
end
