--[[
 Get information about a movie from IMDb

 Copyright © 2009-2010 VideoLAN and AUTHORS

 Authors:  Jean-Philippe André (jpeg@videolan.org)

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
--]]

-- TODO: Use simplexml module to simplify parsing

-- Global variables
url = nil          -- string
title = nil        -- string
titles = {}        -- table, see code below

-- Some global variables: widgets
dlg = nil          -- dialog
txt = nil          -- text field
list = nil         -- list widget
button_open = nil  -- button widget
html = nil         -- rich text (HTML) widget
waitlbl = nil      -- text label widget

-- Script descriptor, called when the extensions are scanned
function descriptor()
    return { title = "IMDb - The Internet Movie Database" ;
             version = "1.0" ;
             author = "Jean-Philippe André" ;
             url = 'http://www.imdb.org/';
             shortdesc = "The Internet Movie Database";
             description = "<center><b>The Internet Movie Database</b></center><br />"
                        .. "Get information about movies from the Internet "
                        .. "Movie Database (IMDb).<br />This Extension will show "
                        .. "you the cast, a short plot summary and a link to "
                        .. "the web page on imdb.org." ;
             icon = icon ;
             capabilities = { "input-listener" } }
end

-- Remove trailing & leading spaces
function trim(str)
    if not str then return "" end
    return string.gsub(str, "^%s*(.*)+%s$", "%1")
end

-- Update title text field. Removes file extensions.
function update_title()
    local item = vlc.input.item()
    local name = item and item:name()
    if name ~= nil then
        name = string.gsub(name, "(.*)(%.%w+)$", "%1")
    end
    if name ~= nil then
        txt:set_text(trim(name))
    end
end

-- Function called when the input (media being read) changes
function input_changed()
    update_title()
end

-- First function to be called when the extension is activated
function activate()
    create_dialog()
end

-- This function is called when the extension is disabled
function deactivate()
end

-- Create the main dialog with a simple search bar
function create_dialog()
    dlg = vlc.dialog("IMDb")
    dlg:add_label("<b>Movie Title:</b>", 1, 1, 1, 1)
    local item = vlc.input.item()
    txt = dlg:add_text_input(item and item:name() or "", 2, 1, 1, 1)
    dlg:add_button("Search", click_okay, 3, 1, 1, 1)
    -- Show, if not already visible
    dlg:show()
end

-- Dialog closed
function close()
    -- Deactivate this extension
    vlc.deactivate()
end

-- Called when the user presses the "Search" button
function click_okay()
    vlc.msg.dbg("[IMDb] Searching for " .. txt:get_text())

    -- Search IMDb: build URL
    title = string.gsub(string.gsub(txt:get_text(), "[%p%s%c]", "+"), "%++", " ")
    url = "http://www.imdb.com/find?s=all&q=" .. string.gsub(title, " ", "+")

    -- Recreate dialog structure: delete useless widgets
    if html then
        dlg:del_widget(html)
        html = nil
    end

    if list then
        dlg:del_widget(list)
        dlg:del_widget(button_open)
        list = nil
        button_open = nil
    end

    -- Ask the user to wait some time...
    local waitmsg = 'Searching for <a href="' .. url .. '">' .. title .. "</a> on IMDb..."
    if not waitlbl then
        waitlbl = dlg:add_label(waitmsg, 1, 2, 3, 1)
    else
        waitlbl:set_text(waitmsg)
    end
    dlg:update()

    -- Download the data
    local s, msg = vlc.stream(url)
    if not s then
        vlc.msg.warn("[IMDb] " .. msg)
        waitlbl:set_text('Sorry, an error occured while searching for <a href="'
                         .. url .. '">' .. title .. "</a>.<br />Please try again later.")
        return
    end

    -- Fetch HTML data
    local data = s:read(65000)
    if not data then
        vlc.msg.warn("[IMDb] Not data received!")
        waitlbl:set_text('Sorry, an error occured while searching for <a href="'
                         .. url .. '">' .. title .. "</a>.<br />Please try again later.")
        return
    end

    -- Probe result & parse it
    if string.find(data, "<h6>Overview</h6>") then
        -- We found a direct match
        parse_moviepage(data)
    else
        -- We have a list of results to parse
        parse_resultspage(data)
    end
end

-- Called when clicked on the "Open" button
function click_open()
    -- Get user selection
    selection = list:get_selection()
    if not selection then return end

    local sel = nil
    for idx, selectedItem in pairs(selection) do
        sel = idx
        break
    end
    if not sel then return end
    local imdbID = titles[sel].id

    -- Update information message
    url = "http://www.imdb.org/title/" .. imdbID .. "/"
    title = titles[sel].title

    dlg:del_widget(list)
    dlg:del_widget(button_open)
    list = nil
    button_open = nil
    waitlbl:set_text("Loading IMDb page for <a href=\"" .. url .. "\">" .. title .. "</a>.")
    dlg:update()

    local s, msg = vlc.stream(url)
    if not s then
        waitlbl:set_text('Sorry, an error occured while looking for <a href="'
                         .. url .. '">' .. title .. "</a>.")
        vlc.msg.warn("[IMDb] " .. msg)
        return
    end

    data = s:read(65000)
    if data and string.find(data, "<h6>Overview</h6>") then
        parse_moviepage(data)
    else
        waitlbl:set_text('Sorry, no results found for <a href="'
                         .. url .. '">' .. title .. "</a>.")
    end
end

-- Parse the results page and find titles, years & URL's
function parse_resultspage(data)
    vlc.msg.dbg("[IMDb] Analysing results page")

    -- Find titles
    titles = {}
    local count = 0

    local idxEnd = 1
    while idxEnd ~= nil do
        -- Find title types
        local titleType = nil
        _, idxEnd, titleType = string.find(data, "<b>([^<]*Titles[^<]*)</b>", idxEnd)
        local _, _, nextTitle = string.find(data, "<b>([^<]*Titles[^<]*)</b>", idxEnd)
        if not titleType then
            break
        else
            -- Find current scope
            local table = nil
            if not nextTitle then
                _, _, table = string.find(data, "<table>(.*)</table>", idxEnd)
            else
                nextTitle = string.gsub(nextTitle, "%(", "%%(")
                nextTitle = string.gsub(nextTitle, "%)", "%%)")
                _, _, table = string.find(data, "<table>(.*)</table>.*"..nextTitle, idxEnd)
            end

            if not table then break end
            local pos = 0
            local thistitle = nil

            -- Find all titles in this scope
            while pos ~= nil do
                local _, _, link = string.find(table, "<a href=\"([^\"]+title[^\"]+)\"", pos)
                if not link then break end -- this would not be normal behavior...
                _, pos, thistitle = string.find(table, "<a href=\"" .. link .. "\"[^>]*>([^<]+)</a>", pos)
                if not thistitle then break end -- this would not be normal behavior...
                local _, _, year = string.find(table, "\((%d+)\)", pos)
                -- Add this title to the list
                count = count + 1
                local _, _, imdbID = string.find(link, "/([^/]+)/$")
                thistitle = replace_html_chars(thistitle)
                titles[count] = { id = imdbID ; title = thistitle ; year = year ; link = link }
            end
        end
    end

    -- Did we find anything at all?
    if not count or count == 0 then
        waitlbl:set_text('Sorry, no results found for <a href="'
                         .. url .. '">' .. title .. "</a>.")
        return
    end

    -- Sounds good, we found some results, let's display them
    waitlbl:set_text(count .. " results found for <a href=\"" .. url .. "\">" .. title .. "</a>.")
    list = dlg:add_list(1, 3, 3, 1)
    button_open = dlg:add_button("Open", click_open, 3, 4, 1, 1)

    for idx, title in ipairs(titles) do
        --list:add_value("[" .. title.id .. "] " .. title.title .. " (" .. title.year .. ")", idx)
        list:add_value(title.title .. " (" .. title.year .. ")", idx)
    end
end

-- Parse a movie description page
function parse_moviepage(data)
    -- Title & year
    title = string.gsub(data, "^.*<title>(.*)</title>.*$", "%1")
    local text = "<h1>" .. title .. "</h1>"
    text = text .. "<h2>Overview</h2><table>"

    -- Real URL
    url = string.gsub(data, "^.*<link rel=\"canonical\" href=\"([^\"]+)\".*$", "%1")
    local imdbID = string.gsub(url, "^.*/title/([^/]+)/.*$", "%1")
    if imdbID then
        url = "http://www.imdb.org/title/" .. imdbID .. "/"
    end

    -- Director
    local director = nil
    _, nextIdx, _ = string.find(data, "<div id=\"director-info\"", 1, true)
    if nextIdx then
        _, _, director = string.find(data, "<a href[^>]+>([%w%s]+)</a>", nextIdx)
    end
    if not director then
        director = "(Unknown)"
    end
    text = text .. "<tr><td><b>Director</b></td><td>" .. director .. "</td></tr>"

    -- Main genres
    local genres = "<tr><td><b>Genres</b></td>"
    local first = true
    for genre, _ in string.gmatch(data, "/Sections/Genres/(%w+)/\">") do
        if first then
            genres = genres .. "<td>" .. genre .. "</td></tr>"
        else
            genres = genres .. "<tr><td /><td>" .. genre .. "</td></tr>"
        end
        first = false
    end
    text = text .. genres

    -- List main actors
    local actors = "<tr><td><b>Cast</b></td>"
    local first = true
    for nm, char in string.gmatch(data, "<td class=\"nm\"><a[^>]+>([%w%s]+)</a></td><td class=\"ddd\"> ... </td><td class=\"char\"><a[^>]+>([%w%s]+)</a>") do
        if not first then
            actors = actors .. "<tr><td />"
        end
        actors = actors .. "<td>" .. nm .. "</td><td><i>" .. char .. "</i></td></tr>"
        first = false
    end
    text = text .. actors .. "</table>"

    waitlbl:set_text("<center><a href=\"" .. url .. "\">" .. title .. "</a></center>")
    if list then
        dlg:del_widget(list)
        dlg:del_widget(button_open)
    end
    html = dlg:add_html(text .. "<br />Loading summary...", 1, 3, 3, 1)
    dlg:update()

    text = text .. "<h2>Plot Summary</h2>"
    local s, msg = vlc.stream(url .. "plotsummary")
    if not s then
        vlc.msg.warn("[IMDb] " .. msg)
        return
    end
    local data = s:read(65000)

    -- We read only the first summary
    _, _, summary = string.find(data, "<p class=\"plotpar\">([^<]+)")
    if not summary then
        summary = "(Unknown)"
    end
    text = text .. "<p>" .. summary .. "</p>"
    text = text .. "<p><h2>Source IMDb</h2><a href=\"" .. url .. "\">" .. url .. "</a></p>"

    html:set_text(text)
end

-- Convert some HTML characters into UTF8
function replace_html_chars(txt)
    if not txt then return nil end
    -- return vlc.strings.resolve_xml_special_chars(txt)
    for num in string.gmatch(txt, "&#x(%x+);") do
        -- Convert to decimal (any better way?)
        dec = 0
        for c in string.gmatch(num, "%x") do
            cc = string.byte(c) - string.byte("0")
            if (cc >= 10 or cc < 0) then
                cc = string.byte(string.lower(c)) - string.byte("a") + 10
            end
            dec = dec * 16 + cc
        end
        txt = string.gsub(txt, "&#x" .. num .. ";", string.char(dec))
    end
    return txt
end

icon = "\137\80\78\71\13\10\26\10\0\0\0\13\73\72\68\82\0\0\0\48\0\0\0\39\8\6\0\0\0\73\209\203\164\0\0\0\6\98\75\71\68\0\255\0\255\0\255\160\189\167\147\0\0\0\9\112\72\89\115\0\0\0\72\0\0\0\72\0\70\201\107\62\0\0\17\68\73\68\65\84\88\195\221\89\9\84\147\215\182\62\25\152\17\100\144\57\33\204\67\152\113\86\80\139\128\56\32\90\108\173\5\177\14\181\34\90\91\135\215\219\246\61\219\190\78\239\246\182\87\159\29\172\56\85\171\40\56\16\198\16\8\9\73\152\231\0\97\70\80\177\212\218\218\94\239\213\118\153\100\191\125\254\36\20\251\122\219\215\183\122\239\91\235\101\173\207\179\207\249\255\144\239\219\103\239\253\239\243\75\200\63\248\35\16\56\146\162\203\27\8\220\39\4\32\138\200\75\83\217\125\53\66\238\189\86\194\26\171\229\145\137\161\68\118\105\65\50\11\32\147\228\30\77\39\10\249\110\82\171\220\67\88\44\22\249\63\253\124\240\254\58\50\210\146\140\164\139\72\65\94\22\105\171\90\200\185\89\239\205\41\60\183\146\28\248\247\87\200\230\63\28\53\87\148\36\37\169\138\151\219\139\10\94\35\67\50\15\174\186\194\143\13\64\133\18\146\178\44\228\159\79\58\57\57\140\148\21\102\16\184\71\103\111\16\89\233\58\214\128\50\130\251\109\135\13\107\64\158\64\110\54\196\145\18\81\150\75\179\100\225\243\29\149\97\29\93\149\254\80\91\28\251\250\3\181\37\249\161\139\203\86\42\14\144\158\158\183\81\192\37\68\225\63\143\248\188\121\126\164\167\241\9\210\63\240\17\57\113\98\43\105\151\45\229\92\175\231\115\26\106\227\241\42\144\228\131\192\174\45\79\154\221\81\21\123\172\171\42\248\110\119\165\55\244\84\122\234\53\85\158\250\238\74\1\180\138\133\146\214\138\200\75\10\209\204\156\59\29\94\228\78\39\143\157\182\246\73\98\97\97\241\143\35\109\101\101\78\138\242\215\18\24\23\162\183\182\161\183\215\178\6\107\103\113\239\106\60\89\234\202\69\100\64\149\64\138\68\57\51\90\42\227\178\187\164\97\205\26\169\191\190\87\234\13\154\74\47\4\79\219\45\241\210\117\75\120\208\85\225\161\83\139\221\117\221\21\238\208\84\226\63\186\125\215\70\135\221\251\183\146\79\15\197\177\106\164\89\191\63\241\117\143\199\16\77\83\6\145\182\202\201\27\111\63\135\222\78\96\223\106\9\224\12\53\4\51\177\75\102\0\171\86\146\54\187\189\106\246\167\61\213\161\119\122\171\125\160\175\154\15\189\85\60\125\79\37\239\33\130\142\128\2\64\45\246\64\1\158\116\212\118\150\187\125\223\94\230\9\101\231\163\51\27\74\195\73\125\73\24\103\184\41\225\247\35\158\247\121\38\129\137\104\36\185\159\148\23\62\205\26\172\155\199\125\48\228\204\46\200\223\65\202\139\182\17\113\201\54\251\246\234\199\182\116\203\99\234\250\228\193\186\126\153\145\184\148\175\213\84\121\107\77\164\77\196\59\203\221\31\65\123\169\171\182\163\212\5\84\87\3\37\198\68\102\29\124\229\49\146\119\97\221\255\158\116\86\230\92\210\170\216\72\210\223\1\178\239\229\93\164\85\182\154\125\179\37\130\51\222\238\65\76\213\162\78\178\42\162\167\102\206\97\141\76\56\209\39\243\135\1\153\0\250\164\124\125\159\84\240\176\87\42\192\56\231\79\18\55\122\27\58\202\220\38\129\196\153\177\173\196\5\218\138\157\161\169\200\11\62\63\22\63\79\116\110\1\41\62\55\139\253\240\246\19\191\157\248\158\93\241\228\90\123\42\185\53\114\128\92\205\207\34\253\181\241\156\187\152\88\199\207\30\36\231\242\223\32\249\5\251\109\90\170\18\159\208\212\204\172\28\84\132\106\135\20\254\48\40\247\129\1\185\143\182\175\90\64\61\14\76\188\27\201\155\136\255\212\235\148\116\75\145\51\51\182\22\207\160\182\150\206\171\242\67\143\222\170\179\38\183\234\109\57\123\95\76\36\142\142\214\191\78\122\206\28\63\162\16\175\103\188\26\30\159\77\106\197\171\216\215\155\99\185\127\29\244\99\77\52\57\147\239\186\221\136\178\50\35\160\171\102\209\91\253\202\232\177\33\101\48\12\43\253\96\72\225\171\31\144\249\62\196\144\209\27\194\70\48\73\158\134\13\37\78\65\61\77\137\78\122\219\8\74\184\89\228\100\26\245\45\34\7\80\93\225\223\254\183\215\54\184\191\245\246\6\242\201\7\11\89\95\141\62\243\203\228\107\202\158\36\199\78\190\67\178\118\191\69\52\170\68\206\55\221\190\156\50\69\22\89\121\80\75\14\126\84\200\109\173\78\73\238\83\206\21\13\213\70\126\63\172\10\98\136\15\43\252\117\131\53\254\218\1\185\47\80\152\72\255\92\200\80\111\155\194\133\122\218\4\74\218\36\160\169\208\17\26\174\76\135\186\75\211\180\245\87\156\160\240\76\204\179\181\69\193\68\37\10\226\92\248\143\112\98\110\206\254\245\93\72\90\255\38\153\104\15\99\125\209\30\69\196\162\76\183\110\69\252\243\131\181\177\93\195\42\33\92\171\13\132\17\149\191\126\88\25\240\16\9\235\6\228\126\12\113\234\245\169\30\159\90\97\166\36\232\212\48\153\4\37\77\209\120\213\129\33\95\127\217\30\49\93\91\87\96\3\146\243\124\133\41\153\55\110\136\199\221\143\254\251\196\213\117\89\164\115\236\46\25\234\255\148\221\34\75\93\164\81\206\255\108\72\21\249\237\181\186\16\36\30\128\196\3\116\35\170\64\45\146\215\83\210\131\53\6\242\52\92\40\113\42\128\122\219\132\159\122\221\20\46\212\211\38\152\72\155\80\91\48\141\17\80\119\201\14\84\249\214\32\191\232\8\185\71\226\231\228\157\152\71\46\30\143\249\251\238\119\115\181\37\50\81\50\91\124\121\13\57\244\238\146\240\126\69\244\247\163\117\129\128\208\83\210\8\29\18\7\10\74\156\146\54\197\186\73\128\41\214\77\30\55\17\55\133\204\212\48\161\48\120\218\126\146\48\5\21\160\188\104\131\228\109\113\180\213\42\47\90\131\248\115\254\121\211\46\28\121\211\239\231\5\192\120\40\121\253\213\197\172\244\140\13\100\99\198\60\1\150\195\175\71\209\235\67\202\128\41\196\253\167\120\125\106\200\240\39\61\110\42\143\140\199\167\132\140\137\56\245\120\227\213\71\201\27\4\216\51\164\21\23\108\140\64\239\159\183\208\203\243\108\224\212\7\124\113\112\128\187\75\114\130\144\236\217\234\241\243\237\105\86\198\62\162\174\158\205\233\144\206\35\85\151\227\211\135\148\161\72\154\137\117\96\202\35\18\31\52\198\122\31\173\241\213\166\18\137\177\206\144\119\55\10\48\120\190\131\146\103\188\238\4\173\140\231\169\215\29\12\2\152\56\183\51\18\159\198\120\157\146\87\229\219\128\18\137\43\12\208\169\242\173\224\196\251\94\165\132\56\241\142\28\180\180\130\123\143\113\165\133\203\88\223\12\166\147\187\67\107\31\21\240\224\90\60\231\254\181\4\210\88\62\103\205\160\50\252\30\146\135\65\133\191\158\18\239\151\249\78\134\75\15\54\96\157\229\60\104\18\121\64\195\85\119\168\191\226\6\117\87\92\161\246\146\11\40\48\94\41\106\46\56\64\213\217\105\32\253\220\110\18\146\207\48\33\207\216\48\99\197\105\12\139\211\86\80\126\210\18\97\1\101\39\204\161\244\184\57\20\31\227\66\73\46\133\25\130\163\21\29\179\132\55\95\14\120\70\126\85\72\148\34\33\103\58\151\144\215\119\251\176\66\230\39\26\162\134\233\89\76\33\4\233\216\131\175\39\167\14\133\31\24\168\9\68\143\251\106\167\38\41\69\183\132\15\13\133\158\80\115\209\19\6\106\66\81\160\144\25\251\25\132\64\175\44\24\250\228\116\12\130\158\170\0\232\173\198\81\26\8\221\85\254\204\156\1\182\206\221\18\63\232\66\116\148\11\64\93\225\11\157\98\31\232\16\11\12\192\181\246\50\111\4\95\223\90\234\13\205\101\17\138\190\154\152\143\6\149\209\71\199\154\230\124\212\165\74\19\244\55\174\38\253\77\233\236\63\31\160\188\243\200\174\237\49\132\188\123\48\158\229\41\204\38\132\43\240\105\44\17\142\14\43\168\199\125\116\83\227\188\173\212\11\10\143\57\131\248\12\31\190\213\204\133\219\157\115\224\78\215\143\248\74\109\28\59\103\163\141\232\156\5\183\59\102\194\151\136\219\70\155\153\183\199\78\226\86\107\12\124\209\134\192\241\86\107\52\131\155\205\145\112\163\41\18\198\155\163\112\12\135\177\250\48\184\86\39\212\142\53\68\130\166\110\229\230\27\237\139\201\173\182\185\102\163\154\45\100\98\56\139\220\30\204\32\196\214\214\12\213\60\207\162\138\242\143\133\31\166\33\131\85\69\75\201\171\43\48\100\138\60\64\252\153\11\20\124\236\14\35\181\209\248\163\179\144\216\44\36\57\19\109\156\227\15\223\70\123\2\201\220\104\12\135\155\77\17\12\49\58\31\71\66\215\27\194\12\107\148\32\142\116\126\189\49\12\198\26\132\72\208\112\255\205\230\8\24\173\15\5\67\217\14\193\178\29\140\85\48\76\135\247\62\28\107\8\251\97\64\30\12\35\245\179\122\46\156\221\232\7\247\227\72\175\202\151\117\240\79\198\48\10\242\179\37\138\146\37\108\105\241\106\178\41\67\24\215\86\230\251\67\183\132\182\185\94\122\26\231\101\167\93\160\171\42\20\73\205\68\47\81\210\177\240\117\215\76\248\75\223\108\128\91\75\1\198\31\131\111\186\99\224\254\208\124\208\94\95\140\88\2\127\29\152\11\119\58\163\224\225\232\34\248\225\90\60\252\48\18\7\95\117\68\192\253\193\249\240\61\218\223\15\47\68\44\128\251\3\184\3\45\33\40\46\28\175\205\99\174\255\13\113\127\112\46\220\237\70\161\13\193\40\80\136\130\66\244\131\10\20\215\16\115\127\160\33\225\20\61\36\145\245\64\26\164\216\232\249\251\58\144\208\96\39\44\81\158\40\199\214\166\252\92\96\141\166\210\3\203\160\187\174\250\188\11\156\63\236\12\215\155\98\208\75\184\213\45\49\24\10\177\240\215\190\88\144\21\174\133\244\180\217\144\185\126\1\12\53\62\5\185\135\211\224\217\77\241\176\45\107\17\156\253\36\21\6\27\30\135\29\91\18\32\103\91\28\60\191\35\1\122\84\155\224\141\151\83\224\185\205\113\144\243\108\60\188\144\189\24\62\252\227\42\184\217\150\0\67\245\75\225\133\157\41\144\189\117\33\236\220\26\199\92\187\122\38\13\119\118\46\238\68\144\65\68\109\40\246\91\216\198\212\207\238\125\249\236\61\238\25\169\134\52\84\165\27\74\171\131\61\7\195\104\35\38\243\11\228\189\215\132\187\219\203\189\176\252\205\208\85\156\113\134\83\239\57\194\112\109\20\140\35\249\175\58\13\113\123\175\55\26\42\10\214\194\162\184\40\72\73\138\133\145\214\45\176\102\85\52\48\231\71\196\154\85\49\80\154\191\157\177\241\23\128\203\181\0\69\217\30\8\10\244\98\214\216\108\54\112\16\212\222\176\110\54\12\52\110\6\75\43\59\195\253\44\54\243\29\60\243\193\185\163\169\240\181\58\148\9\171\155\77\161\186\62\89\32\244\41\102\245\124\112\177\195\172\80\213\130\173\252\90\131\0\62\207\150\236\205\137\101\197\44\92\71\92\61\131\3\164\23\4\55\90\177\142\151\158\116\208\31\127\215\30\134\85\52\185\162\48\249\12\49\255\157\38\10\36\249\43\96\233\34\31\88\149\236\15\35\45\153\144\190\250\71\1\243\230\132\192\251\239\110\101\108\46\151\5\150\150\150\40\96\39\68\132\241\153\181\103\50\19\96\219\166\165\140\237\235\227\14\141\85\57\224\228\100\207\204\15\188\176\6\86\36\199\48\246\182\172\56\252\173\57\248\92\10\196\112\10\197\35\40\22\24\197\204\222\247\242\52\102\69\245\106\82\87\97\20\96\110\206\37\118\182\22\184\11\107\49\153\63\33\39\15\133\28\110\18\205\128\146\19\246\218\220\119\236\176\100\134\97\130\70\98\98\70\161\39\34\225\111\253\209\112\250\163\84\131\55\57\150\208\169\216\134\2\162\38\5\248\8\120\240\244\83\134\235\102\102\92\224\112\204\161\166\116\39\132\133\240\152\181\23\114\150\193\235\175\60\206\216\222\124\23\80\162\56\71\71\131\128\35\239\111\134\45\27\151\48\246\198\13\11\225\174\102\30\211\13\92\111\8\97\118\64\83\19\51\112\66\84\98\33\174\23\145\122\73\218\143\79\231\224\0\123\34\185\188\152\45\46\76\39\25\235\195\226\100\23\60\30\20\231\218\234\143\190\57\77\75\235\254\88\67\56\122\159\238\68\4\230\64\20\156\249\120\165\129\160\185\37\168\21\155\39\5\248\250\120\193\180\105\54\224\233\233\10\158\30\174\48\221\126\26\118\50\28\80\160\0\161\81\192\238\231\146\225\213\3\171\13\2\120\6\1\246\118\211\152\185\191\159\23\216\77\179\2\59\123\103\16\125\158\14\19\45\129\216\214\4\193\104\109\144\174\167\202\15\52\242\232\145\11\165\31\90\201\27\63\33\245\85\171\167\8\8\114\38\2\129\179\33\252\8\223\34\239\99\31\177\248\148\45\228\190\99\163\165\15\173\81\172\201\227\205\225\88\2\195\225\47\189\145\112\250\195\21\204\15\114\56\22\208\89\179\25\214\165\25\4\44\125\108\62\216\218\90\51\246\194\5\177\224\50\195\17\109\54\200\75\178\127\20\176\35\25\254\213\40\128\207\155\129\226\178\193\206\40\192\97\186\61\238\26\7\172\109\236\225\248\225\85\48\209\26\138\45\77\0\109\231\117\26\131\128\225\2\201\73\75\101\219\105\76\226\213\143\246\71\238\110\214\4\190\92\204\6\221\18\178\55\219\39\235\208\107\110\189\47\101\59\117\247\201\67\245\88\5\48\140\232\185\32\20\190\197\18\55\85\64\187\124\19\10\48\228\64\198\83\203\192\205\213\201\144\160\79\38\130\187\155\211\20\1\134\36\206\217\158\8\175\236\79\53\10\112\193\240\218\1\142\14\134\16\250\227\155\25\176\62\125\1\99\207\157\29\1\227\109\139\176\23\243\6\218\21\119\97\14\244\200\162\134\11\196\39\44\21\45\39\49\137\83\31\21\16\29\233\138\255\114\16\214\100\186\157\141\19\26\179\166\219\91\109\80\75\194\191\30\196\54\99\172\62\68\79\43\194\55\93\66\56\117\100\185\65\0\215\18\218\170\179\38\119\96\79\78\58\8\67\125\25\251\229\3\89\224\234\234\192\8\144\21\239\152\220\129\23\119\175\124\36\7\228\37\59\38\115\224\208\123\153\176\41\115\17\99\71\71\225\3\173\113\49\182\55\124\218\88\234\212\21\2\232\146\70\246\253\249\98\179\121\81\93\35\81\150\255\100\7\216\108\22\153\25\110\67\254\176\221\131\100\165\123\112\45\204\136\155\151\187\205\18\77\117\248\196\128\60\0\107\114\176\126\72\17\8\119\58\66\80\192\50\99\146\90\64\171\52\19\158\92\99\16\240\250\171\153\176\56\62\146\177\63\249\207\221\224\234\98\207\228\128\172\104\59\10\240\100\214\23\199\69\192\130\185\33\198\132\119\135\186\138\231\96\250\116\67\8\165\174\152\11\225\66\111\198\142\141\14\129\235\205\113\208\95\205\163\93\177\174\83\236\13\234\170\136\222\195\151\123\176\10\181\17\101\217\234\255\222\98\115\56\44\98\101\101\70\252\125\172\205\104\84\205\112\182\89\210\85\37\188\73\19\8\183\17\79\100\254\112\187\45\16\227\115\5\227\89\54\199\6\154\171\158\129\39\210\102\50\63\250\214\193\167\225\169\117\241\104\179\224\202\249\189\96\111\79\61\107\9\213\69\187\32\40\128\111\124\14\112\152\103\1\214\63\216\146\185\0\186\20\79\131\149\149\227\228\115\128\94\167\223\121\49\39\1\31\158\97\76\79\70\5\96\163\7\29\146\176\174\195\69\95\153\149\182\221\32\138\159\19\96\250\132\4\216\112\233\123\54\87\23\219\5\61\213\97\19\244\32\131\49\168\163\9\53\172\20\64\107\69\60\228\29\91\9\249\39\86\66\95\205\124\144\94\94\6\159\125\184\28\26\203\151\129\66\180\2\46\228\174\128\30\69\10\92\58\185\12\31\72\201\208\85\189\4\10\63\163\246\50\40\56\177\28\46\230\166\64\201\185\20\124\72\198\66\79\117\36\20\156\76\133\188\79\147\33\255\120\10\94\91\6\226\139\41\48\164\138\193\198\210\139\57\68\117\150\243\181\106\49\158\65\100\81\154\157\159\62\228\30\147\140\17\249\47\9\152\225\200\188\6\176\51\55\99\5\252\233\96\200\94\105\126\164\162\27\119\65\45\246\166\231\98\253\136\210\27\110\53\9\96\188\209\27\147\140\143\101\142\15\95\52\121\195\176\194\11\174\169\120\112\179\129\7\3\50\15\184\81\207\131\177\90\79\60\87\120\224\232\133\235\124\102\237\122\157\23\140\170\60\209\187\30\72\144\206\61\153\251\40\232\181\107\74\15\160\45\13\118\197\122\236\134\245\109\232\253\230\242\168\114\236\219\210\8\105\99\94\255\156\63\153\252\139\47\41\168\58\51\14\135\109\231\230\76\48\187\217\66\209\169\208\82\250\66\182\189\204\75\167\22\243\241\248\232\133\167\48\236\90\169\93\198\51\194\139\89\111\43\161\215\120\204\216\94\202\195\126\159\199\180\229\173\56\111\41\246\192\227\166\167\241\154\39\208\119\162\204\90\9\93\243\156\28\59\177\165\105\41\114\211\182\149\122\64\99\89\84\190\233\124\188\60\57\242\215\255\247\35\216\223\102\50\181\87\37\57\59\160\225\245\210\243\129\91\58\37\65\208\92\226\163\107\41\245\213\35\160\165\212\143\65\115\137\0\154\139\5\104\251\64\19\142\116\222\82\226\131\16\96\75\206\135\70\17\143\25\155\139\189\13\160\235\197\6\52\27\239\111\42\242\198\57\253\142\47\51\34\244\141\69\222\218\246\138\64\168\149\44\95\49\208\150\70\212\53\113\230\95\94\52\48\235\107\203\248\159\189\106\180\182\54\167\249\96\31\26\226\226\191\103\135\48\97\239\206\160\165\251\114\130\17\33\75\247\226\184\119\39\181\3\18\247\229\248\39\237\223\21\48\9\156\39\238\207\241\75\218\159\237\157\180\15\241\47\57\62\73\251\119\10\16\126\244\90\210\190\157\254\204\184\31\113\96\23\222\187\43\32\209\240\183\38\145\240\218\75\97\11\115\143\204\143\202\59\187\206\250\242\213\108\146\123\252\105\242\234\254\152\223\246\174\20\43\19\221\50\174\173\141\185\185\185\25\135\109\124\88\252\222\96\27\241\211\53\230\12\156\179\61\154\9\155\232\8\151\223\254\178\23\64\196\252\145\134\202\199\9\60\72\199\134\111\13\226\241\41\160\107\105\136\84\196\106\227\184\138\5\15\82\216\240\101\2\91\255\197\66\182\118\124\1\27\38\22\177\225\193\18\108\219\151\27\239\89\105\184\143\1\174\233\86\176\64\63\229\111\127\183\138\253\245\64\34\251\134\58\137\61\164\198\35\228\181\77\228\206\104\22\249\127\245\249\47\186\18\100\209\248\10\217\95\0\0\0\37\116\69\88\116\100\97\116\101\58\99\114\101\97\116\101\0\50\48\49\49\45\48\49\45\49\57\84\48\48\58\48\54\58\52\57\43\48\49\58\48\48\68\30\34\193\0\0\0\37\116\69\88\116\100\97\116\101\58\109\111\100\105\102\121\0\50\48\48\57\45\48\51\45\49\56\84\48\48\58\52\55\58\52\53\43\48\49\58\48\48\85\20\179\1\0\0\0\25\116\69\88\116\83\111\102\116\119\97\114\101\0\65\100\111\98\101\32\73\109\97\103\101\82\101\97\100\121\113\201\101\60\0\0\0\0\73\69\78\68\174\66\96\130"
