--
-- Copyright (C) 2014-2015 by Fabian Lipp <fabian.lipp@gmx.de>
-- ------------------------------------------------------------
-- 
-- This file may be distributed and/or modified under the
-- conditions of the LaTeX Project Public License, either version 1.2
-- of this license or (at your option) any later version.
-- The latest version of this license is in:
--
--    http://www.latex-project.org/lppl.txt
--
-- and version 1.2 or later is part of all distributions of LaTeX 
-- version 1999/12/01 or later.
--

require("lualibs")
--require("debugger")()
local inspect = require('inspect')

local point = require'path_point'
local pathLine = require'path_line'
--local bezier3 = require'path_bezier3'

luatodonotes = {}

-- strings used to switch to standard catcodes for LaTeX packages
local catcodeStart = "\\makeatletter"
local catcodeEnd = "\\makeatother"

local currentPage = 1

local const1In = string.todimen("1in") -- needed for calculations of page borders
                                       -- (used as a constant in TeX)
-- constants set in sty-file
-- + noteInnerSep (inner sep used for tikz nodes)
-- + noteInterSpace (vertical space between notes)
-- + routingAreaWidth (width of the track routing area for opo-leaders)
-- + minNoteWidth (width that must be available for labels to consider the left or
--     right border of the page for placing labels)
-- + distanceNotesPageBorder (distance from the page borders to the outmost point
--     of the labels)
-- + distanceNotesText (horizontal distance between the labels and the text area)
-- + rasterHeight (height of raster for po leader algorithm)
-- + todonotesDebug (activate debug outputs when true)
--
-- values are filled into local variables in function initTodonotes (from
-- corresponding fields luatodonotes.*)
local noteInnerSep = nil
local noteInterSpace = nil
local routingAreaWidth = nil
local minNoteWidth = nil
local distanceNotesPageBorder = nil
local distanceNotesText = nil
local rasterHeight = nil
local todonotesDebug = nil


-- stores information about available algorithms
local positioningAlgos = {}
local splittingAlgos = {}
local leaderTypes = {}

local positioning = nil
local splitting = nil
local leaderType = nil
function luatodonotes.setPositioningAlgo(algo)
    if positioningAlgos[algo] ~= nil then
        positioning = positioningAlgos[algo]
    else
        positioning = positioningAlgos["inputOrderStacks"]
        tex.print("\\PackageWarningNoLine{luatodonotes}{Invalid value for parameter positioning: " .. algo .. "}")
    end
end
function luatodonotes.setSplittingAlgo(algo)
    if splittingAlgos[algo] ~= nil then
        splitting = splittingAlgos[algo]
    else
        splitting = splittingAlgos["none"]
        tex.print("\\PackageWarningNoLine{luatodonotes}{Invalid value for parameter split: " .. algo .. "}")
    end
end
function luatodonotes.setLeaderType(typ)
    if leaderTypes[typ] ~= nil then
        leaderType = leaderTypes[typ]
    else
        leaderType = leaderTypes["opo"]
        tex.print("\\PackageWarningNoLine{luatodonotes}{Invalid value for parameter leadertype: " .. typ .. "}")
    end
end

-- stores the notes for the current page
luatodonotes.notesForPage = {}
local notesForPage = luatodonotes.notesForPage
luatodonotes.notesForNextPage = {}
local notesForNextPage = luatodonotes.notesForNextPage
-- Fields for each note:
-- index: numbers notes in whole document
-- indexOnPage: index of the note in the notesForPage array
-- textbox: links to a hbox that contains the text, which is displayed inside
--     the note
-- origInputX, origInputY: position in which the todo-command was issued
-- inputX, inputY: position to which the leader should be attached (can have a
--     certain offset to origInputX/Y)
-- heightLeft, heightRight: height of the contained text when placed on
--     left/right side
-- pageNr: absolute number of page on which site for note is placed
-- rightSide: true means the note should be placed on the right side;
--     otherwise left side is meant
-- fontsize: fontsize used for paragraph in that the note was defined
-- baselineskip: \baselineskip in the paragraph in that the note was defined
-- normalbaselineskip: \normalbaselineskip in the paragraph in that the note was defined
-- outputX, outputY: position on which the north west anchor of the note should
--     be placed
-- lineColor: color of line connecting note to text
-- backgroundColor: color of background of note
-- borderColor: color of border of note
-- leaderWidth: width of leader (used as argument for tikz line width)
-- sizeCommand: fontsize command given as parameter for this note
--
-- Additional fields for text area:
-- noteType: constant string "area"
-- origInputEndX, origInputEndY: position at which the todo area ends
-- pageNrEnd: absolute number of page on which todo area ends
-- lineCountInArea: highest line index in area
-- linesInArea: positions of lines in area (to detect page/column break)

-- stores the areas for the labels on the current page
-- (calculated in function calcLabelAreaDimensions())
local labelArea = {}

-- stores the positions of the text lines on every page
local linePositions = {}
-- Fields for every position:
-- 1: position of baseline
-- 2: upper bound of line (baseline + height)
-- 3: lower bound of line (baseline - depth)

-- variables used for construction of linePositions list when reading the file
local linePositionsCurPage = {}
local linePositionsPageNr = 0


-- *** metatable for note objects ***
local noteMt = {}
-- getHeight(): yield heightLeft or heightRight depending on rightSide (implemented by metatable)
function noteMt:getHeight()
    if self.rightSide then
        return self.heightRight
    else
        return self.heightLeft
    end
end
function noteMt:getLabelAnchorY()
    local leaderAnchor = positioning.leaderAnchor
    local y
    if leaderAnchor == "north east" then
        y = self.outputY
    elseif leaderAnchor == "east" then
        y = self.outputY - noteInnerSep - self:getHeight() / 2
    else
        error("Invalid anchor for algorithm")
    end

    if positioning.leaderShift then
        y = y + self.leaderShiftY
    end

    return y
end
function noteMt:getInTextAnchorTikz()
    return "(" .. self.inputX .. "sp," .. self.inputY .. "sp)"
end
function noteMt:getLabelAnchorTikz()
    local leaderAnchor = positioning.leaderAnchor
    if leaderAnchor == "north east" and self.rightSide then
        leaderAnchor = "north west"
    elseif leaderAnchor == "east" and self.rightSide then
        leaderAnchor = "west"
    end

    local shiftStr = ""
    if positioning.leaderShift then
        shiftStr = "[shift={(" .. self.leaderShiftX .. "sp," .. self.leaderShiftY .. "sp)}]"
    end

    return "(" .. shiftStr .. " @todonotes@" .. self.index .. " note." .. leaderAnchor ..  ")"
end
function noteMt:boxForNoteText(rightSide)
    local area = labelArea:getArea(rightSide)
    local noteWidth
    if area == nil then
        noteWidth = minNoteWidth
    else
        noteWidth = area.noteWidth - 2*noteInnerSep
    end
    local retval = "\\directlua{tex.box[\"@todonotes@notetextbox\"] = " ..
        "node.copy_list(luatodonotes.notesForPage[" .. self.indexOnPage .. "].textbox)}"
    retval = retval .. "\\parbox{" .. noteWidth .. "sp}" ..
        "{\\raggedright\\unhbox\\@todonotes@notetextbox}"
    return retval
end

function noteMt:getClipPathForTodoArea()
    -- detext which lines are in same column/page as start of area
    local lineCount = self.lineCountInArea
    local maxLine = 1
    local lines = self.linesInArea
    local lastY = lines[1]
    while maxLine < lineCount do
        if lines[maxLine + 1] < lastY then
            maxLine = maxLine + 1
            lastY = lines[maxLine]
        end
    end

    local function nodename(i, corner)
        return "(@todonotes@" .. self.index .. "@" .. i .. " area" .. corner .. ")"
    end
    local path = nodename(1, "NW")
    local pathLeft = ""
    if maxLine == 1 then
        -- only one line
        path = path .. " -- " .. nodename(1, "NE") ..
            " -- " .. nodename(1, "SE")
    else
        path = path .. " -- " .. nodename(1, "NE") ..
            " decorate[@todonotes@todoarea] { -- " .. nodename(1, "SE") .. "}"
    end
    for i = 2, maxLine do
        if i == lineCount then
            -- area does not use the whole line
            path = path .. " -| " .. nodename(i, "NE") ..
                " -- " .. nodename(i, "SE")
        else
            -- area uses whole line
            path = path .. " -- " .. nodename(i, "NE") ..
                " decorate[@todonotes@todoarea] { -- " .. nodename(i, "SE") .. "}"
        end
        pathLeft = " -- " .. nodename(i, "SW") ..
            " decorate[@todonotes@todoarea] { -- " .. nodename(i, "NW") .. "}" ..
            pathLeft
    end
    path = path .. pathLeft .. " -| " .. nodename(1, "SW") .. "-- cycle"
    return path
end



-- *** label areas ***
-- stores areas for placing labels on current page
function labelArea:getArea(rightSide)
    if rightSide then
        return self.right
    else
        return self.left
    end
end
-- yields the x-coordinate of the boundary of the label that is pointing
-- towards the text
function labelArea:getXTextSide(rightSide)
    if rightSide then
        return self.right.left
    else
        return self.left.right
    end
end
function labelArea:isOneSided()
    if self.right == nil or self.left == nil then
        return true
    else
        return false
    end
end



-- divides notes in two lists (for left and right side)
-- side must be stored in note.rightSide for every note before using this function
local function segmentNotes(notes)
    local availableNotesLeft = {}
    local availableNotesRight = {}
    for k, v in pairs(notes) do
        if v.rightSide == true then
            table.insert(availableNotesRight, k)
        else
            table.insert(availableNotesLeft, k)
        end
    end
    return availableNotesLeft, availableNotesRight
end



-- is called by the sty-file when all settings (algorithms etc.) are made
function luatodonotes.initTodonotes()
    -- fill local variables (defined at begin of file) with package options
    noteInnerSep = luatodonotes.noteInnerSep
    noteInterSpace = luatodonotes.noteInterSpace
    routingAreaWidth = luatodonotes.routingAreaWidth
    minNoteWidth = luatodonotes.minNoteWidth
    distanceNotesPageBorder = luatodonotes.distanceNotesPageBorder
    distanceNotesText = luatodonotes.distanceNotesText
    rasterHeight = luatodonotes.rasterHeight
    todonotesDebug = luatodonotes.todonotesDebug

    if positioning.needLinePositions then
        luatexbase.add_to_callback("post_linebreak_filter", luatodonotes.callbackOutputLinePositions, "outputLinePositions")
        tex.print("\\@starttoc{lpo}")
        tex.print("\\directlua{lpoFileStream = \\the\\tf@lpo}")
    end
end


-- valid values for noteType: nil/"" (for point in text), "area"
function luatodonotes.addNoteToList(index, drawLeader, noteType)
    if next(notesForPage) ~= nil
        and index <= notesForPage[#notesForPage].index then
        -- Index is the same as for one of the previous note.
        -- This can happen when commands are read multiple times
        -- => don't add anything to list in this case
        return
    end
    local newNote = {}
    newNote.index = index
    newNote.textbox = node.copy_list(tex.box["@todonotes@notetextbox"])
    newNote.baselineskip = tex.dimen["@todonotes@baselineskip"]
    newNote.normalbaselineskip = tex.dimen["@todonotes@normalbaselineskip"]
    newNote.fontsize = tex.dimen["@todonotes@fontsize"]
    newNote.lineColor = tex.toks["@todonotes@toks@currentlinecolor"]
    newNote.backgroundColor = tex.toks["@todonotes@toks@currentbackgroundcolor"]
    newNote.borderColor = tex.toks["@todonotes@toks@currentbordercolor"]
    newNote.leaderWidth = tex.toks["@todonotes@toks@currentleaderwidth"]
    newNote.sizeCommand = tex.toks["@todonotes@toks@sizecommand"]
    newNote.drawLeader = drawLeader
    if noteType == "area" then
        newNote.noteType = "area"
        newNote.lineCountInArea = 0
    -- else: newNote.noteType = nil (default value)
    end
    setmetatable(newNote, {__index = noteMt})
    newNote.indexOnPage = #notesForPage + 1
    notesForPage[newNote.indexOnPage] = newNote
end

function luatodonotes.clearNotes()
    -- delete the texts for the notes on this page from memory
    -- (garbage collection does not work for nodes)
    for _, v in pairs(notesForPage) do
        node.free(v.textbox)
    end
    luatodonotes.notesForPage = notesForNextPage
    notesForPage = luatodonotes.notesForPage
    -- update indexOnPage for the new notes
    for k, v in pairs(notesForPage) do
        v.indexOnPage = k
    end

    currentPage = currentPage + 1
end

function luatodonotes.processLastLineInTodoArea()
    -- LaTeX counter is accessed as TeX count by prefixing c@
    ind = tex.count["c@@todonotes@numberoftodonotes"]
    val = tex.count["c@@todonotes@numberofLinesInArea"]
    notesForPage[#notesForPage].lineCountInArea = val
end


-- *** constructing the linePositions list ***
function luatodonotes.linePositionsNextPage()
    linePositionsPageNr = linePositionsPageNr + 1
    linePositionsCurPage = {}
    linePositions[linePositionsPageNr] = linePositionsCurPage
end

function luatodonotes.linePositionsAddLine(ycoord, lineheight, linedepth)
    local baseline = ycoord - tex.pageheight
    linePositionsCurPage[#linePositionsCurPage + 1] = {baseline, baseline + lineheight, baseline - linedepth}
end


function luatodonotes.getInputCoordinatesForNotes()
    tex.sprint(catcodeStart)
    for k, v in ipairs(notesForPage) do
        local nodename = "@todonotes@" .. v.index .. " inText"

        tex.sprint("\\pgfextractx{\\@todonotes@extractx}{\\pgfpointanchor{" ..
            nodename .. "}{center}}")
        tex.sprint("\\pgfextracty{\\@todonotes@extracty}{\\pgfpointanchor{" ..
            nodename .. "}{center}}")
        tex.print("\\directlua{luatodonotes.notesForPage[" .. k .. "].origInputX = " ..
            "tex.dimen[\"@todonotes@extractx\"]}")
        tex.print("\\directlua{luatodonotes.notesForPage[" .. k .. "].origInputY = " ..
            "tex.dimen[\"@todonotes@extracty\"]}")

        if v.noteType == "area" then
            nodename = nodename .. "End"
            tex.sprint("\\pgfextractx{\\@todonotes@extractx}{\\pgfpointanchor{" ..
                nodename .. "}{center}}")
            tex.sprint("\\pgfextracty{\\@todonotes@extracty}{\\pgfpointanchor{" ..
                nodename .. "}{center}}")
            tex.print("\\directlua{luatodonotes.notesForPage[" .. k .. "].origInputEndX = " ..
                "tex.dimen[\"@todonotes@extractx\"]}")
            tex.print("\\directlua{luatodonotes.notesForPage[" .. k .. "].origInputEndY = " ..
                "tex.dimen[\"@todonotes@extracty\"]}")

            notesForPage[k].linesInArea = {}
            for i = 1, v.lineCountInArea do
                nodename = "@todonotes@" .. v.index .. "@" .. i .. " areaSW"
                    tex.sprint("\\pgfextracty{\\@todonotes@extracty}{\\pgfpointanchor{" ..
                        nodename .. "}{center}}")
                tex.print("\\directlua{luatodonotes.notesForPage[" .. k .. "].linesInArea[" ..
                    i .. "] = " .. "tex.dimen[\"@todonotes@extracty\"]}")
            end
        end
    end
    tex.sprint(catcodeEnd)
end

function luatodonotes.calcLabelAreaDimensions()
    local routingAreaSpace = 0
    if leaderType.needRoutingArea then
        routingAreaSpace = routingAreaWidth
    end

    local top = tex.voffset + tex.dimen.topmargin + const1In
    local bottom = top + tex.dimen.headheight + tex.dimen.headsep + tex.dimen.textheight + tex.dimen.footskip
    local currentsidemargin = tex.hoffset + tex.dimen["@todonotes@currentsidemargin"] + const1In

    local left = {}
    left.top = -top
    left.bottom = -bottom
    left.left = distanceNotesPageBorder
    left.right = currentsidemargin - distanceNotesText - routingAreaSpace
    if left.right - left.left < minNoteWidth then
        -- not enough space left of text
        left = nil
    else
        left.noteWidth = left.right - left.left
    end

    local right = {}
    right.top = -top
    right.bottom = -bottom
    right.left = currentsidemargin + tex.dimen.textwidth + distanceNotesText + routingAreaSpace
    right.right = tex.pagewidth - distanceNotesPageBorder
    if right.right - right.left < minNoteWidth then
        -- not enough space right of text
        right = nil
    else
        right.noteWidth = right.right - right.left
    end

    local text = {}
    text.left = currentsidemargin
    text.right = currentsidemargin + tex.dimen.textwidth

    labelArea.left = left
    labelArea.right = right
    labelArea.text = text
end

function luatodonotes.calcHeightsForNotes()
    -- function has to be called outside of a tikzpicture-environment
    tex.sprint(catcodeStart)
    for k, v in ipairs(notesForPage) do
        -- store height for note
        -- (is determined by creating a box with the text and reading its size)

        -- left side
        tex.sprint("\\savebox{\\@todonotes@heightcalcbox}" ..
            "{" .. v.sizeCommand .. v:boxForNoteText(false) .. "}")
        tex.sprint("\\@todonotes@heightcalcboxdepth=\\dp\\@todonotes@heightcalcbox")
        tex.sprint("\\@todonotes@heightcalcboxheight=\\ht\\@todonotes@heightcalcbox")
        tex.sprint("\\directlua{luatodonotes.notesForPage[" .. k .. "].heightLeft = " ..
            "tex.dimen[\"@todonotes@heightcalcboxheight\"]" ..
            " + tex.dimen[\"@todonotes@heightcalcboxdepth\"]}")

        -- right side
        tex.sprint("\\savebox{\\@todonotes@heightcalcbox}" ..
            "{" .. v.sizeCommand .. v:boxForNoteText(true) .. "}")
        tex.sprint("\\@todonotes@heightcalcboxdepth=\\dp\\@todonotes@heightcalcbox")
        tex.sprint("\\@todonotes@heightcalcboxheight=\\ht\\@todonotes@heightcalcbox")
        tex.sprint("\\directlua{luatodonotes.notesForPage[" .. k .. "].heightRight = " ..
            "tex.dimen[\"@todonotes@heightcalcboxheight\"]" ..
            " + tex.dimen[\"@todonotes@heightcalcboxdepth\"]}")

        -- store pageNr for note
        -- (is determined as reference to a label)
        tex.sprint("\\directlua{luatodonotes.notesForPage[" .. k .. "].pageNr = " ..
            "\\zref@extract{@todonotes@" .. v.index .. "}{abspage}}")
        if v.noteType == "area" then
            tex.sprint("\\directlua{luatodonotes.notesForPage[" .. k .. "].pageNrEnd = " ..
                "\\zref@extract{@todonotes@" .. v.index .. "@end}{abspage}}")
        end
    end
    tex.sprint(catcodeEnd)
end

local inputShiftX = string.todimen("-0.05cm") -- sensible value depends on shape of mark
function luatodonotes.printNotes()
    print("Drawing notes for page " .. currentPage)

    -- seperate notes that should be placed on another page
    -- This can occur when note is in a paragraph which doesn't fit on the
    -- current page and is thus moved to the next one. But the \todo-command is
    -- still read before the shipout of the current page is done
    luatodonotes.notesForNextPage = {}
    notesForNextPage = luatodonotes.notesForNextPage
    local k=1
    while k <= #notesForPage do
        local v = notesForPage[k]
        if v.pageNr == 0 then
            -- Notes without a page number occur when the zref label is not
            -- defined correctly. This happens with notes in a
            -- \caption-command, e.g.
            -- In this case two version of the note are stored and we drop the
            -- note that does not have a valid page number (the other note
            -- seems to have one).
            table.remove(notesForPage, k)
            if todonotesDebug then
                print("deleting note: " .. k .. " (" .. v.index .. ")")
            end
        elseif v.pageNr ~= currentPage then
            table.insert(notesForNextPage, v)
            table.remove(notesForPage, k)
            if todonotesDebug then
                print("moving note to next page: " .. k .. " (" .. v.index .. ")")
            end
        else
            -- update index here (needed if a note was deleted before)
            v.indexOnPage = k
            k = k + 1
        end
    end

    -- add offset to input coordinates
    for _, v in pairs(notesForPage) do
        if v.noteType ~= "area" then
            v.inputX = v.origInputX + inputShiftX
            local bls = v.baselineskip
            if v.baselineskip == 0 then
                bls = v.normalbaselineskip
            end
            v.inputY = v.origInputY - 1.3 * (bls - v.fontsize)
        else
            v.inputX = v.origInputX
            v.inputY = v.origInputY
        end
    end

    splitting.algo()
    if positioning.twoSided then
        local notesLeft, notesRight = segmentNotes(notesForPage)
        if #notesLeft > 0 then
            positioning.algo(notesLeft, false)
        end
        if #notesRight > 0 then
            positioning.algo(notesRight, true)
        end
    else
        positioning.algo()
    end
    for k, v in ipairs(notesForPage) do
        if todonotesDebug then
            local function outputWithPoints(val)
                if val ~= nil then
                    return val .. " (" .. number.topoints(val, "%s%s") .. ")"
                else
                    return ""
                end
            end
            print("-----------------")
            print(k .. ": ")
            print("index:        " .. v.index)
            print("origInputX:   " .. v.origInputX)
            print("origInputY:   " .. v.origInputY)
            if (v.noteType ~= nil) then
                print("noteType:     " .. v.noteType)
                print("origInputEndX:" .. v.origInputEndX)
                print("origInputEndY:" .. v.origInputEndY)
                print("lineCountInArea:" .. v.lineCountInArea)
                print("linesInArea  :" .. inspect(v.linesInArea))
            else
                print("noteType:     nil")
            end
            print("inputX:       " .. v.inputX)
            print("inputY:       " .. v.inputY)
            print("outputX:      " .. v.outputX)
            print("outputY:      " .. v.outputY)
            if (v.rasterSlots ~= nil) then
                print("rasterSlots:  " .. v.rasterSlots)
            end
            print("baselineskip: " .. outputWithPoints(v.baselineskip))
            print("nbaselineskip:" .. outputWithPoints(v.normalbaselineskip))
            print("fontsize:     " .. outputWithPoints(v.fontsize))
            print("textbox:      " .. inspect(v.textbox))
            print("height:       " .. outputWithPoints(v:getHeight()))
            print("heightLeft:   " .. outputWithPoints(v.heightLeft))
            print("heightRight:  " .. outputWithPoints(v.heightRight))
            print("rightSide:    " .. tostring(v.rightSide))
            if v.pageNr ~= nil then
                print("pageNr:       " .. v.pageNr)
            end
            print("lineColor:    " .. v.lineColor)
            print("backgroundColor:" .. v.backgroundColor)
            print("borderColor:  " .. v.borderColor)
            print("leaderWidth:  " .. v.leaderWidth)
            print("sizeCommand:  " .. v.sizeCommand)
            print("drawLeader:   " .. tostring(v.drawLeader))
        end

        -- print note
        tex.print(catcodeStart)
        tex.print("\\node[@todonotes@notestyle,anchor=north west," ..
            "fill=" .. v.backgroundColor .. ",draw=" .. v.borderColor .. "," ..
            "font=" .. v.sizeCommand .. "] " ..
            "(@todonotes@" .. v.index ..
            " note) at (" .. v.outputX .. "sp," .. v.outputY .. "sp) {" ..
            v:boxForNoteText(v.rightSide) .. "};")
        tex.print(catcodeEnd)


        -- output debugging hints on page
        if todonotesDebug then
            tex.print("\\node[anchor=north west,text=blue,fill=white,rectangle] at (@todonotes@" .. v.index .. " inText) {" .. v.index .. "};")
            tex.print("\\draw[green,fill] (@todonotes@" .. v.index .. " inText) circle(2pt);")
            tex.print("\\draw[black,fill] (@todonotes@" .. v.index .. " inText) circle(0.2pt);")
            if v.noteType == "area" then
                tex.print("\\draw[red,fill] (@todonotes@" .. v.index .. " inTextEnd) circle(2pt);")
            end

            if (v.noteType ~= nil) then
                print(v:getClipPathForTodoArea())
                tex.print("\\draw[blue] " .. v:getClipPathForTodoArea() .. ";")
                --for i=1, v.lineCountInArea do
                    --tex.print(" (@todonotes@" .. v.index .. "@" .. i .. " areaSW) -- ")
                --end
                --tex.print("cycle;")
            end
        end
    end
    -- draw leader
    leaderType.algo()

    -- draw mark in text
    for _, v in pairs(notesForPage) do
        if v.drawLeader ~= false and v.noteType ~= "area" then
            local shiftStr = "(" .. v.inputX .. "sp," .. v.inputY .. "sp)"
            tex.print("\\draw[@todonotes@textmark," ..
                "draw=" .. v.lineColor .. ",fill=" .. v.lineColor .. "," ..
                "shift={" .. shiftStr .. "}," ..
                "scale around={0.5:(-0,-0)},shift={(-0.5,-0.1)}]" ..
                "(1,0) .. controls (0.5,0.2) and (0.65,0.3) .." ..
                "(0.5,0.7) .. controls (0.35,0.3) and (0.5,0.2) .." .. 
                "(0,0) -- cycle;")
        end
    end

    --- draw label areas when requested
    if todonotesDebug then
        local area = labelArea.left
        if area ~= nil then
            tex.print("\\draw[blue] (" .. area.left .. "sp," .. area.top .. "sp) rectangle (" ..
                area.right .. "sp," .. area.bottom .. "sp);")
        end
        area = labelArea.right
        if area ~= nil then
            tex.print("\\draw[blue] (" .. area.left .. "sp," .. area.top .. "sp) rectangle (" ..
                area.right .. "sp," .. area.bottom .. "sp);")
            end
    end
end




-- ********** Helper Functions **********

-- * comparators for table.sort() *
-- (yields true if first parameter should be placed before second parameter in
-- sorted table)
local function compareNoteInputXAsc(note1, note2)
    if note1.inputX < note2.inputX then
        return true
    end
end

local function compareNoteIndInputXAsc(key1, key2)
    if notesForPage[key1].inputX < notesForPage[key2].inputX then
        return true
    end
end

local function compareNoteIndInputXDesc(key1, key2)
    if notesForPage[key1].inputX > notesForPage[key2].inputX then
        return true
    end
end

local function compareNoteIndInputYDesc(key1, key2)
    local v1 = notesForPage[key1]
    local v2 = notesForPage[key2]
    if v1.inputY > v2.inputY then
        return true
    elseif v1.inputY == v2.inputY then
        if v1.inputX < v2.inputX then
            return true
        end
    end
end

-- * callbacks for Luatex *
local function appendStrToTokenlist(tokenlist, str)
    str:gsub(".", function(c)
        tokenlist[#tokenlist + 1] = {12, c:byte(), 0}
    end)
end
-- writes commands into the node tree that print the absolute position on the
-- page to the output file (streamId is taken from lpoFileStream) at the
-- beginning of every line
-- should be called as post_linebreak_filter
local ID_GLYPH_NODE = node.id("glyph")
local ID_HLIST_NODE = node.id("hlist")
function luatodonotes.callbackOutputLinePositions(head)
    while head do
        if head.id == ID_HLIST_NODE then
            -- check if we are in the main text area (hlists in, e.g.,
            -- tikz nodes should have other widths)
            if head.width == tex.dimen.textwidth then
                -- check if there is a glyph in this hlist
                -- -> then we consider it a text line
                local foundGlyph = false
                local glyphTest = head.head
                while glyphTest do
                    if glyphTest.id == ID_GLYPH_NODE then
                        foundGlyph = true
                        break
                    end
                    glyphTest = glyphTest.next
                end

                if foundGlyph then
                    local w = node.new("whatsit", "write") -- 8/1
                    w.stream = lpoFileStream
                    local tokenlist = {
                        {12,  92, 0}, -- \
                        {12,  64, 0}, -- @
                        {12, 116, 0}, -- t
                        {12, 111, 0}, -- o
                        {12, 100, 0}, -- d
                        {12, 111, 0}, -- o
                        {12, 110, 0}, -- n
                        {12, 111, 0}, -- o
                        {12, 116, 0}, -- t
                        {12, 101, 0}, -- e
                        {12, 115, 0}, -- s
                        {12,  64, 0}, -- @
                        {12, 108, 0}, -- l
                        {12, 105, 0}, -- i
                        {12, 110, 0}, -- n
                        {12, 101, 0}, -- e
                        {12, 112, 0}, -- p
                        {12, 111, 0}, -- o
                        {12, 115, 0}, -- s
                        {12, 105, 0}, -- i
                        {12, 116, 0}, -- t
                        {12, 105, 0}, -- i
                        {12, 111, 0}, -- o
                        {12, 110, 0}, -- n
                        {12, 123, 0} -- {
                    }
                    t = token.create("@todonotes@pdflastypos")
                    tokenlist[#tokenlist + 1] = t
                    tokenlist[#tokenlist + 1] = {12, 125, 0}
                    tokenlist[#tokenlist + 1] = {12, 123, 0}
                    appendStrToTokenlist(tokenlist, tostring(head.height))
                    tokenlist[#tokenlist + 1] = {12, 125, 0}
                    tokenlist[#tokenlist + 1] = {12, 123, 0}
                    appendStrToTokenlist(tokenlist, tostring(head.depth))
                    tokenlist[#tokenlist + 1] = {12, 125, 0}
                    w.data = tokenlist
                    head.head = node.insert_before(head.head,head.head,w)

                    local w = node.new("whatsit", "pdf_save_pos") -- 8/23
                    head.head = node.insert_before(head.head,head.head,w)
                end
            end
        end
        head = head.next
    end
    return true
end





-- ********** Leader Drawing Algorithms **********

local function drawLeaderPath(note, path)
    if note.drawLeader == false then
        return
    end
    local clipPath
    if note.noteType == "area" then
        clipPath = note:getClipPathForTodoArea()
        tex.print("\\begin{scope}")
        tex.print("\\clip (current page.north west) rectangle (current page.south east) ")
        tex.print(clipPath)
        tex.print(";")
    end
    tex.print("\\draw[@todonotes@leader,draw=" .. note.lineColor ..
        ",line width=" .. note.leaderWidth .. ",name path=leader] " .. path .. ";")
    if note.noteType == "area" then
        tex.print("\\path[name path=clipping] " .. clipPath .. ";")
        tex.print("\\fill[@todonotes@leader,name intersections={of=leader and clipping, by=x,sort by=leader},fill=" .. note.lineColor .. "] (x) circle(3pt);")
        tex.print("\\end{scope}")
    end
end


-- ** leader drawing: s-leaders
local function drawSLeaders()
    for k, v in ipairs(notesForPage) do
        drawLeaderPath(v, v:getLabelAnchorTikz() ..
            " -- " .. v:getInTextAnchorTikz())
    end
end
leaderTypes["s"] = {algo = drawSLeaders}



-- ** leader drawing: opo-leaders
local function drawOpoLeader(v, opoShift, rightSide)
    if rightSide then
        opoShift = - opoShift
    end
    drawLeaderPath(v, v:getLabelAnchorTikz() .. " -- +(" .. opoShift .. "sp,0) " ..
        "|- " .. v:getInTextAnchorTikz())
end
local function drawOpoGroup(group, directionDown, rightSide)
    if directionDown == nil then
        for _, v2 in ipairs(group) do
            drawOpoLeader(notesForPage[v2], 0, rightSide)
        end
    else
        if #group == 1 then
            -- place p-section of leader in center of routing area
            local opoShift = distanceNotesText / 2 + routingAreaWidth / 2
            drawOpoLeader(notesForPage[group[1]], opoShift, rightSide)
        else
            local leaderDistance = routingAreaWidth / (#group - 1)

            -- initialise shift value
            local nextOpoShift, move
            if directionDown then
                nextOpoShift = distanceNotesText / 2 + routingAreaWidth
                move = -leaderDistance
            else
                nextOpoShift = distanceNotesText / 2
                move = leaderDistance
            end

            -- cycle through group
            for _, v2 in ipairs(group) do
                drawOpoLeader(notesForPage[v2], nextOpoShift, rightSide)
                nextOpoShift = nextOpoShift + move
            end
        end
    end
end
local function drawOpoLeadersSide(notes, rightSide)
    table.sort(notes, compareNoteIndInputYDesc)

    local lastDirectionDown = nil
    local group = {}
    local prevNote
    for _, ind in ipairs(notes) do
        local v = notesForPage[ind]

        local leaderAnchorY = v:getLabelAnchorY()
        if leaderAnchorY > v.inputY then
            newDirectionDown = true
        elseif leaderAnchorY < v.inputY then
            newDirectionDown = false
        else
            newDirectionDown = nil
        end

        if lastDirectionDown == newDirectionDown and
                prevNote ~= nil and
                -- following conditions check that leaders would really intersect
                -- otherwise we can start a new group
                ((newDirectionDown and leaderAnchorY >= prevNote.inputY) or
                (not newDirectionDown and v.inputY >= prevNote:getLabelAnchorY())) then
            -- note belongs to group
            table.insert(group, ind)
        else
            -- draw leaders for group
            drawOpoGroup(group, lastDirectionDown, rightSide)

            -- initialise new group with this note
            lastDirectionDown = newDirectionDown
            group = {ind}
        end

        prevNote = v
    end
    drawOpoGroup(group, lastDirectionDown, rightSide)
end
local function drawOpoLeaders()
    local notesLeft, notesRight = segmentNotes(notesForPage)
    if #notesLeft > 0 then
        drawOpoLeadersSide(notesLeft, false)
    end
    if #notesRight > 0 then
        drawOpoLeadersSide(notesRight, true)
    end
end
leaderTypes["opo"] = {algo = drawOpoLeaders,
    needRoutingArea = true}



-- ** leader drawing: po-leaders
local function drawPoLeaders()
    for _, v in ipairs(notesForPage) do
        drawLeaderPath(v, v:getLabelAnchorTikz() .. " -| " .. v:getInTextAnchorTikz())
    end
end
leaderTypes["po"] = {algo = drawPoLeaders}



-- ** leader drawing: os-leaders
local function drawOsLeaders()
    for _, v in ipairs(notesForPage) do
        local cornerX
        if v.rightSide then
            cornerX = labelArea.right.left - distanceNotesText / 2 - routingAreaWidth
        else
            cornerX = labelArea.left.right + distanceNotesText / 2 + routingAreaWidth
        end
        drawLeaderPath(v, v:getInTextAnchorTikz() ..
            " -- (" .. cornerX .. "sp,0 |- 0," .. v.inputY .. "sp) -- " ..
            v:getLabelAnchorTikz())
    end
end
leaderTypes["os"] = {algo = drawOsLeaders,
    needRoutingArea = true}



-- ** leader drawing: s-Bezier-leaders
-- additional fields for each note:
--   leaderArmY
--   movableControlPointX
--   optimalPositionX
--   currentForce
--   forceLimitDec
--   forceLimitInc

-- settings for algorithm
local maxIterations = 1000
local factorRepulsiveControlPoint = 1
local factorAttractingControlPoint = 1
local stopCondition = 65536 -- corresponds to 1pt

local function constructCurve(l)
    local curve = {}

    -- site
    curve[1] = {}
    curve[1].x = l.inputX
    curve[1].y = l.inputY

    -- unmovable control point (middle point of site and movable control point)
    curve[2] = {}
    curve[2].x = (l.inputX + l.movableControlPointX) / 2
    curve[2].y = (l.inputY + l.leaderArmY) / 2

    -- movable control point
    curve[3] = {}
    curve[3].x = l.movableControlPointX
    curve[3].y = l.leaderArmY

    -- port
    curve[4] = {}
    curve[4].x = labelArea:getXTextSide(l.rightSide)
    curve[4].y = l.leaderArmY

    return curve
end
local function getPointOnCurve(t, curve)
    if #curve ~= 4 then
        error("4 points needed for a Bezier-curve. Given size was: " .. #curve)
    end

    local x = (1 - t) * (1 - t) * (1 - t) * curve[1].x +
        3 * t * (1 - t) * (1 - t) * curve[2].x +
        3 * t * t * (1 - t) * curve[3].x +
        t * t * t * curve[4].x

    local y = (1 - t) * (1 - t) * (1 - t) * curve[1].y +
        3 * t * (1 - t) * (1 - t) * curve[2].y +
        3 * t * t * (1 - t) * curve[3].y +
        t * t * t * curve[4].y;

    return x, y
end
local function getDistance(line1, line2)
    local t1, t2 = pathLine.line_line_intersection(line1.x1, line1.y1, line1.x2, line1.y2,
            line2.x1, line2.y1, line2.x2, line2.y2)
    if 0 <= t1 and t1 <= 1 and 0 <= t2 and t2 <= 1 then
        -- the lines do intersect
        return 0
    end

    local d1 = pathLine.hit(line2.x1, line2.y1, line1.x1, line1.y1, line1.x2, line1.y2)
    local d2 = pathLine.hit(line2.x2, line2.y2, line1.x1, line1.y1, line1.x2, line1.y2)
    local d3 = pathLine.hit(line1.x1, line1.y1, line2.x1, line2.y1, line2.x2, line2.y2)
    local d4 = pathLine.hit(line1.x2, line1.y2, line2.x1, line2.y1, line2.x2, line2.y2)
    return math.sqrt(math.min(d1, d2, d3, d4))
end
local function checkCurveApproximation(curve1, curve2)
    -- these lists will contain the sections of the approximation of the two curves
    local sectionsCurve1 = {}
    local sectionsCurve2 = {}

    -- get line segments of the first curve
    local numberOfSectionsCurve1 = luatodonotes.numberOfCurvePartitions
    local temp1X, temp1Y = getPointOnCurve(0, curve1)
    local i = 1
    while i <= numberOfSectionsCurve1 do
        local t = i / numberOfSectionsCurve1
        local temp2X, temp2Y = getPointOnCurve(t, curve1)
        local line = {}
        line.x1 = temp1X
        line.y1 = temp1Y
        line.x2 = temp2X
        line.y2 = temp2Y
        table.insert(sectionsCurve1, line)
        temp1X, temp1Y = temp2X, temp2Y
        i = i + 1
    end

    -- get line segments of the second curve
    local numberOfSectionsCurve2 = luatodonotes.numberOfCurvePartitions
    temp1X, temp1Y = getPointOnCurve(0, curve2)
    i = 1
    while i <= numberOfSectionsCurve2 do
        local t = i / numberOfSectionsCurve2
        local temp2X, temp2Y = getPointOnCurve(t, curve2)
        local line = {}
        line.x1 = temp1X
        line.y1 = temp1Y
        line.x2 = temp2X
        line.y2 = temp2Y
        table.insert(sectionsCurve2, line)
        temp1X, temp1Y = temp2X, temp2Y
        i = i + 1
    end

    -- get the minimal distance of the 2 curve approximations
    local minDistance = math.huge
    for _, line1 in pairs(sectionsCurve1) do
        for _, line2 in pairs(sectionsCurve2) do
            local distance = getDistance(line1, line2)
            if distance <= minDistance then
                minDistance = distance
            end
        end
    end

    return minDistance
end
local function computeRepulsiveControlPointForces()
    for k1, l1 in pairs(notesForPage) do
        for k2, l2 in pairs(notesForPage) do
            if k1 ~= k2 then
                -- curves of the leaders
                local curve1 = constructCurve(l1)
                local curve2 = constructCurve(l2)

                local distance = checkCurveApproximation(curve1, curve2);

                -- check if R1 has to be increased or decreased to increase the distance of the 2 curves
                -- if curve1 is bent into the direction of curve2, R1 has to be decreased
                local actualR = math.abs(labelArea:getXTextSide(l1.rightSide) - l1.movableControlPointX)
                if ((l1.inputY < l1.leaderArmY and
                        l2.leaderArmY < l1.leaderArmY) or
                        (l1.inputY > l1.leaderArmY and
                        l2.leaderArmY > l1.leaderArmY)) then
                    -- R1 has to be increased
                    local desiredR = math.abs(labelArea:getXTextSide(l1.rightSide) - l1.optimalPositionX)
                    local diff = math.abs(desiredR - actualR)
                    if distance == 0 then
                        distance = 0.01
                    end
                    local force = diff / distance
                    local newForce = force * factorRepulsiveControlPoint
                    l1.currentForce = l1.currentForce + newForce
                    l1.forceLimitDec = math.min(l1.forceLimitDec, distance * 0.45)
                else
                    -- R1 has to be decreased
                    if distance == 0 then
                        distance = 0.01
                    end
                    local force = actualR / distance
                    local newForce = -force * factorRepulsiveControlPoint
                    l1.currentForce = l1.currentForce + newForce
                    local oldLim = l1.forceLimitInc
                    l1.forceLimitInc = math.min(l1.forceLimitInc, distance * 0.45)
                    --if oldLim ~= l1.forceLimitInc then
                        --print(k1 .. ": Reduced forceLimitInc from " .. oldLim .. " to " .. l1.forceLimitInc .. " because of " .. k2 .. " (distance: " .. distance .. ")")
                    --end
                end
            end
        end
    end
end
local function computeAttractingControlPointForces()
    for _, l in pairs(notesForPage) do
        local desiredR = math.abs(labelArea:getXTextSide(l.rightSide) - l.optimalPositionX)
        local actualR = math.abs(labelArea:getXTextSide(l.rightSide) - l.movableControlPointX)
        local newForce = (desiredR - actualR) * factorAttractingControlPoint
        l.currentForce = l.currentForce + newForce
    end
end
local function applyForces(v)
    --print("force on note " .. v.index .. ": " .. v.currentForce .. " (limit: +" .. v.forceLimitInc .. ", -" .. v.forceLimitDec .. ")")

    -- limit the force so the movable control point is between the port and the optimal position
    local actualR = math.abs(labelArea:getXTextSide(v.rightSide) - v.movableControlPointX)
    local differenceR = math.abs(labelArea:getXTextSide(v.rightSide) - v.optimalPositionX) - actualR
    if (v.currentForce < 0 and math.abs(v.currentForce) > actualR) then
        v.currentForce = (-1) * actualR
    end
    if (v.currentForce > 0 and v.currentForce > differenceR) then
        v.currentForce = differenceR
    end

    -- limit the force so 2 curves do not get too close to each other and do not cross
    if v.currentForce > v.forceLimitInc then
        v.currentForce = v.forceLimitInc
    end
    if v.currentForce < (-1) * v.forceLimitDec then
        v.currentForce = (-1) * v.forceLimitDec
    end
    v.forceLimitDec = math.huge
    v.forceLimitInc = math.huge

    if v.rightSide then
        v.movableControlPointX = v.movableControlPointX - v.currentForce
    else
        v.movableControlPointX = v.movableControlPointX + v.currentForce
    end

    --print("force on note " .. v.index .. ": " .. v.currentForce)
    local c = v.currentForce
    v.currentForce = 0
    return c
end
local function getAngle(centerX, centerY, x, y)
    local vectorX = x - centerX
    local vectorY = y - centerY
    local length = math.sqrt((vectorX ^ 2) + (vectorY ^ 2))

    vectorX = vectorX / length
    vectorY = vectorY / length

    local radAngle = math.acos(vectorX)
    local degAngle = (radAngle * 180) / math.pi

    if vectorY < 0 then
        degAngle = 360 - degAngle
    end

    return degAngle
end
local function solveQuadraticEquation(a, b, c)
    local discr = (b * b) - (4 * a * c)

    if discr < 0 then
        error("Fehler bei der Berechnung das optimalen Punktes")
    end

    local solution1 = ((-b) + math.sqrt(discr)) / (2 * a)
    local solution2 = ((-b) - math.sqrt(discr)) / (2 * a)

    if solution1 < 0 and solution2 < 0 then
        error("no positive solution")
    end

    if solution1 < solution2 then
        return solution2
    else
        return solution1
    end
end
local function computeOptimalPosition(v)
    local distance = point.distance(v.inputX, v.inputY, labelArea:getXTextSide(v.rightSide), v.leaderArmY)

    -- the angle at the port between the point and the movable control point
    local tempAngle = getAngle(v.inputX, v.inputY, labelArea:getXTextSide(v.rightSide), v.leaderArmY)

    local gamma
    if v.rightSide then
        if tempAngle < 180 then
            gamma = tempAngle
        else
            gamma = 360 - tempAngle
        end
    else
        if tempAngle < 180 then
            gamma = 180 - tempAngle
        else
            gamma = tempAngle - 180
        end
    end

    -- a quadratic formula has to be solved to get the optimal position
    local a = 3
    local b = 2 * distance * math.cos(math.rad(gamma))
    local c = -(distance * distance)

    local r = solveQuadraticEquation(a, b, c)

    if v.rightSide then
        v.optimalPositionX = labelArea:getXTextSide(v.rightSide) - r
    else
        v.optimalPositionX = labelArea:getXTextSide(v.rightSide) + r
    end
end
local function drawSBezierLeaders()
    for _, v in pairs(notesForPage) do
        -- initialise leader
        v.leaderArmY = v:getLabelAnchorY()
        v.movableControlPointX = labelArea:getXTextSide(v.rightSide)
        v.currentForce = 0
        v.forceLimitDec = math.huge
        v.forceLimitInc = math.huge
    end

    luatodonotes.numberOfCurvePartitions = #notesForPage * 3

    for _, v in pairs(notesForPage) do
        computeOptimalPosition(v)
    end

    -- main loop
    local proceed = true
    local loopCounter = 0
    while (proceed and loopCounter < maxIterations) do
        if todonotesDebug then
            print("Iteration " .. loopCounter)
        end

        -- compute forces
        computeRepulsiveControlPointForces()
        computeAttractingControlPointForces()

        -- apply forces
        proceed = false
        for _, l in pairs(notesForPage) do
            local diff = applyForces(l)
            if diff > stopCondition then
                proceed = true
            end
        end

        loopCounter = loopCounter + 1
    end

    if todonotesDebug then
        print("End of Force-directed algo, number of iterations: " .. loopCounter)
    end

    -- draw
    for _, v in pairs(notesForPage) do
        local curve = constructCurve(v)
        local unmovableStr = "(" .. curve[2].x .. "sp," .. curve[2].y .. "sp)"
        local movableStr = "(" .. curve[3].x .. "sp," .. curve[3].y .. "sp)"
        drawLeaderPath(v, v:getLabelAnchorTikz() .. " .. controls " ..
            movableStr .. " and " .. unmovableStr .. " .. " ..
            v:getInTextAnchorTikz())

        -- draw control points when requested
        if todonotesDebug then
            local optimalStr = "(" .. v.optimalPositionX .. "sp," .. v.leaderArmY .. "sp)"
            tex.print("\\node[anchor=north west,text=pink,fill=white,rectangle] at " .. optimalStr .. " {" .. v.index .. "};")
            tex.print("\\node[anchor=north west,text=red,fill=white,rectangle] at " .. movableStr .. " {" .. v.index .. "};")
            tex.print("\\node[anchor=north west,text=orange,fill=white,rectangle] at " .. unmovableStr .. " {" .. v.index .. "};")
            tex.print("\\draw[red,fill] " .. movableStr .. " circle(2pt);")
            tex.print("\\draw[orange,fill] " .. unmovableStr .. " circle(2pt);")
            tex.print("\\draw[pink,fill] " .. optimalStr .. " circle(1pt);")
        end
    end
end
leaderTypes["sBezier"] = {algo = drawSBezierLeaders}





-- ********** Positioning Algorithms **********

-- ** helper functions

-- finds the index in the list given as parameter with the minimum angle
-- the function used for computation of the angle is given as second parameter
-- (the alphaFormula gets the note, to which the angle should be computed, as
-- the only parameter)
local function findIndexMinAlpha(availableNotesIndex, alphaFormula)
    local minAlpha = math.huge -- infinity
    local minIndex = -1

    for k, v in pairs(availableNotesIndex) do
        local alpha = alphaFormula(notesForPage[v])
        if alpha < minAlpha then
            minAlpha = alpha
            minIndex = k
        end
    end

    return minIndex
end



-- ** partition into stacks
local function getMeanYHeight(stack)
    -- TODO: Alternative: nicht das arithmetische Mittel verwenden, sondern
    -- Mittelpunkt zwischen dem obersten und untersten Punkt
    local sumY = 0
    local height = 0
    for _, v in pairs(stack) do
        sumY = sumY + notesForPage[v].inputY
        height = height + notesForPage[v]:getHeight() + 2 * noteInnerSep + noteInterSpace
    end

    local area = labelArea:getArea(notesForPage[stack[1]].rightSide)

    local meanY = sumY / #stack
    local height = height - noteInterSpace
    if meanY + (height/2) > area.top then
        meanY = area.top - (height/2)
    elseif meanY - (height/2) < area.bottom then
        meanY = area.bottom + (height/2)
    end
    return meanY, height
end
local function stacksIntersect(stackTop, stackBottom)
    local topMeanY, topHeight = getMeanYHeight(stackTop)
    local topLower = topMeanY - topHeight/2

    local bottomMeanY, bottomHeight = getMeanYHeight(stackBottom)
    local bottomUpper = bottomMeanY + bottomHeight/2

    if topLower - bottomUpper < noteInterSpace then
        return true
    else
        return false
    end
end
local function findStacks(notesOnSide)
    local notes = table.copy(notesOnSide)
    table.sort(notes, compareNoteIndInputYDesc)

    -- list that contains stacks
    -- is initialized by putting all notes as single stacks ordered by their inputY
    local stacks = {}
    for _, v in pairs(notes) do
        table.insert(stacks, {v})
    end

    -- Collapse Stacks where needed
    local i = 1
    while i <= #stacks - 1 do
        if stacksIntersect(stacks[i], stacks[i+1]) then
            collapsedStacks = true
            for _, v in pairs(stacks[i+1]) do
                table.insert(stacks[i], v)
            end
            table.remove(stacks,i+1)
            if i > 1 then
                -- as stack i has increased in size we look at the previous
                -- stack again in next iteration
                i = i - 1
            end
        else
             -- look at next stack in next iteration
            i = i + 1
        end
    end

    return stacks
end


-- ** positioning: inText
local function posInText()
    -- trivial algorithm
    -- places notes in text on position where todo-command was issued
    for k, v in ipairs(notesForPage) do
        v.outputX = v.inputX
        v.outputY = v.inputY
    end
end
positioningAlgos["inText"] = {algo = posInText,
    leaderAnchor = "north west",
    leaderShift = false,
    twoSided = false}



-- ** positioning: inputOrderStacks
local function placeNotesInputOrder(stack, yStart, rightSide)
    local freeY = yStart

    for _, k in ipairs(stack) do
        local v = notesForPage[k]
        v.outputX = labelArea:getArea(rightSide).left
        v.outputY = freeY
        freeY = freeY - v:getHeight() - 2 * noteInnerSep - noteInterSpace
    end
end
local function posInputOrderStacks(notesOnSide, rightSide)
    table.sort(notesOnSide, compareNoteIndInputYDesc)

    local stacks = findStacks(notesOnSide)

    -- place stacks
    for k, stack in pairs(stacks) do
        local meanY, height = getMeanYHeight(stack)
        local stackStart = meanY + height / 2
        placeNotesInputOrder(stack, stackStart, rightSide)
    end
end
positioningAlgos["inputOrderStacks"] = {algo = posInputOrderStacks,
    leaderAnchor = "east",
    leaderShift = false,
    twoSided = true}



-- ** positioning: inputOrder
-- start at top and place notes below each other on left/right side
-- notes are placed in the order induced by their y-coordinates
local function posInputOrder(notes, rightSide)
    table.sort(notes, compareNoteIndInputYDesc)
    placeNotesInputOrder(notes, labelArea:getArea(rightSide).top, rightSide)
end
positioningAlgos["inputOrder"] = {algo = posInputOrder,
    leaderAnchor = "east",
    leaderShift = false,
    twoSided = true}



-- ** positioning: sLeaderNorthEast
local function posSLeaderNorthEast(notes, rightSide)
    local noteY = labelArea:getArea(rightSide).top

    local alphaFormula
    local noteX = labelArea:getXTextSide(rightSide)
    local outputX = labelArea:getArea(rightSide).left
    if rightSide then
        alphaFormula = function (note)
            return (noteY - note.inputY) / (noteX - note.inputX)
        end
    else
        alphaFormula = function (note)
            return (noteY - note.inputY) / (note.inputX - noteX)
        end
    end

    while #notes > 0 do
        local minIndex = findIndexMinAlpha(notes, alphaFormula)

        -- place note identified by minIndex
        local note = notesForPage[notes[minIndex]]
        note.outputX = outputX
        note.outputY = noteY
        noteY = noteY - note:getHeight() - 2 * noteInnerSep - noteInterSpace

        table.remove(notes, minIndex)
    end
end
positioningAlgos["sLeaderNorthEast"] = {algo = posSLeaderNorthEast,
    leaderAnchor = "north east",
    leaderShift = false,
    twoSided = true}



-- ** positioning: sLeaderNorthEastBelow
local function placeNotesNorthEastBelow(stack, yStart, rightSide)
    -- calculate minimum height of all notes
    local minHeight = math.huge -- (infinity)
    for _, v in pairs(stack) do
        if notesForPage[v]:getHeight() < minHeight then
            minHeight = notesForPage[v]:getHeight()
        end
    end
    local leaderShiftY = (- minHeight - 2 * noteInnerSep) / 2

    local noteY = yStart
    local availableNotes = table.copy(stack)

    local alphaFormula
    local noteX = labelArea:getXTextSide(rightSide)
    local outputX = labelArea:getArea(rightSide).left
    if rightSide == true then
        alphaFormula = function (note)
            return ((noteY + leaderShiftY) - note.inputY) / (noteX - note.inputX)
        end
    else
        alphaFormula = function (note)
            return ((noteY + leaderShiftY) - note.inputY) / (note.inputX - noteX)
        end
    end
    while #availableNotes > 0 do
        local minIndex = findIndexMinAlpha(availableNotes, alphaFormula)

        -- place note identified by minIndex
        local note = notesForPage[availableNotes[minIndex]]
        note.outputX = outputX
        note.outputY = noteY
        note.leaderShiftX = 0
        note.leaderShiftY = leaderShiftY
        noteY = noteY - note:getHeight() - 2 * noteInnerSep - noteInterSpace

        table.remove(availableNotes, minIndex)
    end
end
local function posSLeaderNorthEastBelow(notes, rightSide)
    placeNotesNorthEastBelow(notes, labelArea:getArea(rightSide).top, rightSide)
end
positioningAlgos["sLeaderNorthEastBelow"] = {algo = posSLeaderNorthEastBelow,
    leaderAnchor = "north east",
    leaderShift = true,
    twoSided = true}



-- ** positioning: sLeaderNorthEastBelowStacks
local function posSLeaderNorthEastBelowStacks(notesOnSide, rightSide)
    local stacks = findStacks(notesOnSide)

    -- place stacks
    for k, stack in pairs(stacks) do
        local meanY, height = getMeanYHeight(stack)
        local stackStart = meanY + height / 2
        placeNotesNorthEastBelow(stack, stackStart, rightSide)
    end
end
positioningAlgos["sLeaderNorthEastBelowStacks"] = {algo = posSLeaderNorthEastBelowStacks,
    leaderAnchor = "north east",
    leaderShift = true,
    twoSided = true}



-- ** positioning: sLeaderEast
local function posSLeaderEast(notes, rightSide)
    local leaderPosY
    local noteY = labelArea:getArea(rightSide).top

    local alphaFormula
    local noteX = labelArea:getXTextSide(rightSide)
    local outputX = labelArea:getArea(rightSide).left
    if rightSide == true then
        alphaFormula = function (note)
            return (leaderPosY - note.inputY) / (noteX - note.inputX)
        end
    else
        alphaFormula = function (note)
            return (leaderPosY - note.inputY) / (note.inputX - noteX)
        end
    end

    local placedNotes = {}
    while #notes > 0 do
        -- build a array with all distinct heights of the notes
        -- first create a set and then convert to sorted array
        local heights = {}
        for _, v in pairs(notes) do
            heights[notesForPage[v]:getHeight()] = true
        end
        heights = table.keys(heights)
        table.sort(heights)

        local chosenIndex = -1
        local chosenH = -1
        for _, h in pairs(heights) do
            if todonotesDebug then
                print("testing height: " .. h)
            end
            leaderPosY = noteY - noteInnerSep - h/2

            -- find point with highest angle
            local minIndex = findIndexMinAlpha(notes, alphaFormula)

            -- found a valid note
            if notesForPage[notes[minIndex]]:getHeight() <= h then
                chosenIndex = minIndex
                chosenH = h
                if todonotesDebug then
                    print("placed note " .. notesForPage[notes[chosenIndex]].index)
                end
                break
            end
        end

        -- place note identified by chosenIndex
        local note = notesForPage[notes[chosenIndex]]
        note.outputX = outputX
        -- let free space above note if needed (if chosenH ~= note:getHeight())
        note.outputY = noteY - (chosenH - note:getHeight()) / 2
        -- no extraordinary free space below note (even if chosenH ~= note:getHeight())
        noteY = note.outputY - note:getHeight() - 2 * noteInnerSep - noteInterSpace
        if todonotesDebug and chosenH ~= note:getHeight() then
            print("Creating free space above note " .. note.index)
        end

        table.insert(placedNotes, notes[chosenIndex])
        table.remove(notes, chosenIndex)
    end

    -- postprocessing: reduce spaces between notes where possible
    for ind, noteNr in pairs(placedNotes) do
        local note = notesForPage[noteNr]

        local aimedPos
        if ind == 1 then
            aimedPos = labelArea:getArea(rightSide).top
        else
            local prevNote = notesForPage[placedNotes[ind-1]]
            aimedPos = prevNote.outputY - prevNote:getHeight() - 2 * noteInnerSep - noteInterSpace
        end

        if todonotesDebug and aimedPos ~= note.outputY then
            print("note " .. note.index .. " got moved:")
            print("aimed: " .. aimedPos)
            print("real:  " .. note.outputY)
        end

        local aimedLeaderAnchorY = aimedPos - noteInnerSep - note:getHeight() / 2
        local realLeaderAnchorY = note.outputY - noteInnerSep - note:getHeight() / 2
        -- it holds: realLeaderAnchorY < aimedLeaderAnchorY (realLeaderAnchor is lower on page)

        -- check if there are points in triangle (aimedLeaderAnchor, note.input, realLeaderAnchor)
        -- we perform this check by calculating the angle of the points referred to note.input
        local pointsInTriangle = false
        local denom
        if rightSide then
            denom = noteX - note.inputX
        else
            denom = note.inputX - noteX
        end
        local aimedLeaderAnchorAngle = (aimedLeaderAnchorY - note.inputY) / denom
        local realLeaderAnchorAngle = (realLeaderAnchorY - note.inputY) / denom
        local minAngle = math.huge
        local minAngleIndex = -1 -- takes index of lowest point in triangle
        for otherInd, otherNote in pairs(notesForPage) do
            if otherInd ~= noteNr and
                ((not rightSide and otherNote.inputX < note.inputX) or
                 (rightSide and otherNote.inputX > note.inputX)) then
                local otherNoteAngle
                if rightSide then
                    otherNoteAngle = (otherNote.inputY - note.inputY) / (otherNote.inputX - note.inputX)
                else
                    otherNoteAngle = (otherNote.inputY - note.inputY) / (note.inputX - otherNote.inputX)
                end

                if (realLeaderAnchorAngle < otherNoteAngle)
                        and (otherNoteAngle < aimedLeaderAnchorAngle) then
                    pointsInTriangle = true
                    if otherNoteAngle < minAngle then
                        minAngle = otherNoteAngle
                        minAngleIndex = otherInd
                    end
                    if todonotesDebug then
                        print(otherNote.index .. " is in triangle for " .. note.index)
                    end
                end
            end
        end

        if not pointsInTriangle then
            -- no points in triangle
            -- => we can move this note to aimedPos
            note.outputY = aimedPos
        else
            -- move note upwards so that leader touches lowest point in triangle
            -- new point for leader anchor is determined by the ray from note.input through the lowest point in triangle (otherNote.input)
            -- TODO: force a certain distance between leader and other points (at the moment a leader can contain endpoints of other leaders)
            local otherNote = notesForPage[minAngleIndex]
            local aimedLeaderAnchorY = note.inputY - (note.inputY - otherNote.inputY) * (note.inputX - noteX) / (note.inputX - otherNote.inputX)
            note.outputY = aimedLeaderAnchorY + noteInnerSep + note:getHeight() / 2
        end
    end
end
positioningAlgos["sLeaderEast"] = {algo = posSLeaderEast,
    leaderAnchor = "east",
    leaderShift = false,
    twoSided = true}



-- ** positioning: poLeaders
local function getRasterAbsolute(rasterHeight, top, rasterIndex)
    return top - (rasterIndex - 1) * rasterHeight
end
 -- distance between line and leader that algorithm tries to reach when there is
 -- no neighbouring line
local poMinDistLine = string.todimen("4pt")
local function getPosAboveLine(linePositionsCurPage, lineInd)
    local line = linePositionsCurPage[lineInd]
    local posAbove
    if linePositionsCurPage[lineInd - 1] ~= nil then
        posAbove = (line[2] + linePositionsCurPage[lineInd - 1][3]) / 2
    end
    if posAbove == nil or posAbove - line[2] > poMinDistLine then
        posAbove = line[2] + poMinDistLine
    end
    return posAbove
end
local function getPosBelowLine(linePositionsCurPage, lineInd)
    local line = linePositionsCurPage[lineInd]
    local posBelow
    if linePositionsCurPage[lineInd + 1] ~= nil then
        posBelow = (line[3] + (linePositionsCurPage[lineInd + 1][2])) / 2
    end
    if posBelow == nil or line[3] - posBelow > poMinDistLine then
        posBelow = line[3] - poMinDistLine
    end
    return posBelow
end
local function posPoLeaders(notes, rightSide, avoidLines)
    local linePositionsCurPage
    if avoidLines then
        linePositionsCurPage = linePositions[currentPage] or {}
    end

    -- number of slots on the whole page
    local area = labelArea:getArea(rightSide)
    local totalNumSlots = math.floor((area.top - area.bottom) / rasterHeight)

    -- calculate number of raster slots for each note
    for _, ind in pairs(notes) do
        local v = notesForPage[ind]
        local height = v:getHeight() + 2 * noteInnerSep + noteInterSpace
        v.rasterSlots = math.ceil(height / rasterHeight)
    end

    -- sort notes by inputY
    table.sort(notes, compareNoteIndInputYDesc)

    -- draw slots
    if todonotesDebug then
        for i = 1,totalNumSlots+1 do
            local pos = area.top - (i-1) * rasterHeight
            tex.print("\\draw[blue,dashed] (0," .. pos .. "sp) -- +(21cm,0);") 
        end
    end

    -- initialise table opt for dynamic program
    -- opt[topPoint, bottomPoint, topSlot, bottomSlot, numberLabeledSites]
    -- opt[a][b][c][d][e] describes length-minimal placement of the labels for
    -- sites from a to b in the raster slots c to d
    -- the leftmost/rightmost e sites between a and b are selected until there
    -- are no more free slots
    local opt = {}
    for a = 1, #notes do
        opt[a] = {}
        for b = a, #notes do
            opt[a][b] = {}
            -- TODO: needed label slots are restricted by points
            -- only create tables for needed slots
            for i = 1, totalNumSlots do
                opt[a][b][i] = {}
                for j = i, totalNumSlots do
                    if i == j then
                        opt[a][b][i][j] = {}
                        opt[a][b][i][j][0] = {}
                        opt[a][b][i][j][0].totalLength = 0
                        opt[a][b][i][j][0].positions = {}
                        opt[a][b][i][j][0].leaderShiftY = {}
                    end
                end
            end
        end
    end

    -- constant use an partial solution without labeled points
    local optEmpty = {}
    optEmpty.totalLength = 0
    optEmpty.positions = {}
    optEmpty.leaderShiftY = {}

    -- fill table opt for dynamic program
    -- numberOfPoints is difference between topPoint and bottomPoint when computing opt
    for numberOfPoints = 1, #notes do
        for topPoint = 1, (#notes - numberOfPoints + 1) do
            -- compute opt[topStrip][bottomStrip]
            local bottomPoint = topPoint + numberOfPoints - 1

            local pointsBetween = {}
            for i = topPoint, bottomPoint do
                table.insert(pointsBetween, notes[i])
            end
            if rightSide then
                table.sort(pointsBetween, compareNoteIndInputXDesc)
            else
                table.sort(pointsBetween, compareNoteIndInputXAsc)
            end

            -- TODO: Einschränken, nicht alle Kombinationen von Slots notwendig
            --       (siehe auch oben)
            -- numberOfSlots is difference between topSlot and bottomSlot when computing opt
            for numberOfSlots = 1, totalNumSlots do
                for topSlot = 1, (totalNumSlots - numberOfSlots + 1) do
                    local bottomSlot = topSlot + numberOfSlots - 1

                    -- DEBUG
                    --print("computing opt[" .. topPoint .. "][" .. bottomPoint ..
                          --"][" .. topSlot .. "][" .. bottomSlot .. "]")

                    opt[topPoint][bottomPoint][topSlot][bottomSlot] = {}
                    opt[topPoint][bottomPoint][topSlot][bottomSlot][0] = {}
                    opt[topPoint][bottomPoint][topSlot][bottomSlot][0].totalLength = 0
                    opt[topPoint][bottomPoint][topSlot][bottomSlot][0].positions = {}
                    opt[topPoint][bottomPoint][topSlot][bottomSlot][0].leaderShiftY = {}

                    -- stelle fest, wie viele Punkte gelabelt werden (bestimme also r)
                    local labeledSites = {}
                    local usedSlots = 0
                    for _, v in pairs(pointsBetween) do
                        local note = notesForPage[v]
                        if usedSlots + note.rasterSlots <= numberOfSlots then
                            usedSlots = usedSlots + note.rasterSlots
                            table.insert(labeledSites, v)
                        else
                            break
                        end
                    end

                    -- TODO: Teste, ob bei kleinerer Anzahl an Slots gleiche Punkte gelabelt werden
                    --  -> dann kann Teillösung übernommen werden

                    -- Mögliche Aufteilungen (Positionierung des Labels für r) testen
                    -- und Optimum auswählen
                    if #labeledSites > 0 then
                        for numLabeledSites = 1, #labeledSites do
                            -- we place rightmost point: labeledSites[#labeledSites]
                            local rIndex = labeledSites[numLabeledSites]
                            local r = notesForPage[rIndex]

                            -- slotIndexR is the slot in that the label for r begins (topmost slot)
                            local bestVal = math.huge
                            local bestOpt = {}
                            -- try all label positions for r (leader should enter the label at east-anchor)
                            for slotIndexR = topSlot, (bottomSlot + 1 - r.rasterSlots) do
                                -- calculate position in which leader arm is placed
                                local labelTopR = getRasterAbsolute(rasterHeight, area.top, slotIndexR)
                                local leaderArmR, leaderShiftR
                                if avoidLines then
                                    leaderArmR = labelTopR - noteInnerSep - r:getHeight() / 2 -- east anchor

                                    -- find first line (from the top) which lower bound is below leaderArmR
                                    local lineBelowInd
                                    for ind, v in pairs(linePositionsCurPage) do
                                        if v[3] <= leaderArmR then
                                            lineBelowInd = ind
                                            break
                                        end
                                    end

                                    -- choose the desired position for the leader arm
                                    -- (later we check if the label is high enough to shift the port to this position)
                                    local desiredPos = leaderArmR
                                    if lineBelowInd == nil then
                                        -- there is no line below the leaderArmR
                                        local lowestLine = linePositionsCurPage[#linePositionsCurPage]
                                        if lowestLine ~= nil and lowestLine[3] - leaderArmR < poMinDistLine then
                                            -- leader is too near to lowest line on page
                                            -- -> use the valid position below this line
                                            desiredPos = getPosBelowLine(linePositionsCurPage, #linePositionsCurPage)
                                        end
                                    else
                                        local lineBelow = linePositionsCurPage[lineBelowInd]
                                        local lineAbove = linePositionsCurPage[lineBelowInd - 1]
                                        if lineBelow ~= nil and leaderArmR - lineBelow[2] < poMinDistLine then
                                            -- leader is too near (or conflicting) to the line below
                                            -- -> move below or above this line (using the position closer to the original one)

                                            local posAbove = getPosAboveLine(linePositionsCurPage, lineBelowInd)
                                            local posBelow = getPosBelowLine(linePositionsCurPage, lineBelowInd)

                                            -- chose position which is closer to east anchor
                                            if posAbove - leaderArmR <= leaderArmR - posBelow then
                                                desiredPos = posAbove
                                            else
                                                desiredPos = posBelow
                                            end
                                        elseif lineAbove ~= nil and lineAbove[3] - leaderArmR < poMinDistLine then
                                            -- leader is too near to the line below
                                            -- -> use the valid position above this line
                                            desiredPos = getPosAboveLine(linePositionsCurPage, lineBelowInd)
                                        end
                                    end

                                    -- check if label is high enough to move leader to desired position
                                    if math.abs(desiredPos - leaderArmR) <= r:getHeight() / 2 + noteInnerSep then
                                        leaderShiftR = desiredPos - leaderArmR
                                        leaderArmR = desiredPos
                                    else
                                        leaderShiftR = 0
                                    end
                                else
                                    leaderArmR = labelTopR - noteInnerSep - r:getHeight() / 2
                                end

                                -- determine index of last point above arm
                                local pointAboveArm = 0
                                for k, ind in pairs(notes) do
                                    v = notesForPage[ind]
                                    if v.inputY >= leaderArmR then
                                        pointAboveArm = k
                                    else
                                        break
                                    end
                                end
                                local numPointsAbove = 0
                                local numPointsBelow = 0
                                for _, v in pairs(pointsBetween) do
                                    if v == rIndex then
                                        break
                                    end

                                    local note = notesForPage[v]
                                    if note.inputY >= leaderArmR then
                                        numPointsAbove = numPointsAbove + 1
                                    else
                                        numPointsBelow = numPointsBelow + 1
                                    end
                                end

                                local optAbove, optBelow
                                if pointAboveArm < topPoint then
                                    optAbove = optEmpty
                                elseif slotIndexR - 1 < topSlot then
                                    optAbove = optEmpty
                                elseif pointAboveArm > bottomPoint then
                                    optAbove = opt[topPoint][bottomPoint][topSlot][slotIndexR - 1][numPointsAbove]
                                else
                                    optAbove = opt[topPoint][pointAboveArm][topSlot][slotIndexR - 1][numPointsAbove]
                                end
                                if pointAboveArm + 1 > bottomPoint then
                                    optBelow = optEmpty
                                elseif slotIndexR + r.rasterSlots > bottomSlot then
                                    optBelow = optEmpty
                                elseif pointAboveArm + 1 < topPoint then
                                    optBelow = opt[topPoint][bottomPoint][slotIndexR + r.rasterSlots][bottomSlot][numPointsBelow]
                                else
                                    optBelow = opt[pointAboveArm + 1][bottomPoint][slotIndexR + r.rasterSlots][bottomSlot][numPointsBelow]
                                end

                                local partitionValid = true
                                if optAbove == nil or optBelow == nil then
                                    partitionValid = false
                                else
                                    local labeledAboveArm = table.keys(optAbove.positions)
                                    local labeledBelowArm = table.keys(optBelow.positions)
                                    if #labeledAboveArm + #labeledBelowArm + 1 ~= numLabeledSites then
                                        partitionValid = false
                                    else
                                        -- test if all of labeledNotes are in one of the sets
                                        -- last element (= r) must not be tested
                                        for testIndex = 1, (numLabeledSites - 1) do
                                            if not table.contains(labeledAboveArm, labeledSites[testIndex])
                                                and not table.contains(labeledBelowArm, labeledSites[testIndex]) then
                                                partitionValid = false
                                            end
                                        end
                                    end
                                end

                                if partitionValid then
                                    local newVal = math.abs(r.inputY - leaderArmR) + optAbove.totalLength + optBelow.totalLength
                                    if newVal < bestVal then
                                        bestVal = newVal
                                        bestOpt = {}
                                        bestOpt.totalLength = newVal
                                        bestOpt.positions = {}
                                        for k, v in pairs(optAbove.positions) do
                                            bestOpt.positions[k] = v
                                        end
                                        for k, v in pairs(optBelow.positions) do
                                            bestOpt.positions[k] = v
                                        end
                                        -- DEBUG
                                        if bestOpt.positions[rIndex] ~= nil then
                                            error("WARNING: Overwriting position of " .. rIndex .. " from " .. bestOpt.positions[rIndex] .. " to " .. slotIndexR)
                                        end
                                        bestOpt.positions[rIndex] = slotIndexR
                                        bestOpt.leaderShiftY = {}
                                        if avoidLines then
                                            for k, v in pairs(optAbove.leaderShiftY) do
                                                bestOpt.leaderShiftY[k] = v
                                            end
                                            for k, v in pairs(optBelow.leaderShiftY) do
                                                bestOpt.leaderShiftY[k] = v
                                            end
                                            bestOpt.leaderShiftY[rIndex] = leaderShiftR
                                        end
                                    end
                                end
                            end
                            if next(bestOpt) ~= nil then -- bestOpt is not an empty table
                                --print("setting opt[" .. topPoint .. "][" .. bottomPoint ..
                                      --"][" .. topSlot .. "][" .. bottomSlot .. "][" .. numLabeledSites .. "] = " .. inspect(bestOpt))
                                opt[topPoint][bottomPoint][topSlot][bottomSlot][numLabeledSites] = bestOpt
                            else
                                --print ("WARNING: Found no valid position for label in opt[" .. topPoint .. "][" .. bottomPoint ..
                                      --"][" .. topSlot .. "][" .. bottomSlot .. "][" .. numLabeledSites .. "] = " .. inspect(bestOpt))
                                opt[topPoint][bottomPoint][topSlot][bottomSlot][numLabeledSites] = nil
                            end
                        end
                    end
                end
            end
        end
    end

    if #notes > 0 then
        --DEBUG
        local maxPlaced = 0
        for i = 1,#notes do
            if opt[1][#notes][1][totalNumSlots][i] ~= nil then
                maxPlaced = i
            end
        end

        if maxPlaced < #notes then
            print("WARNING: could not fit all labels on page")
        end

        local res = opt[1][#notes][1][totalNumSlots][maxPlaced]
        local positions = res.positions
        local leaderShiftY = res.leaderShiftY
        if todonotesDebug then
            local length = res.totalLength
            -- in console
            print("----------------")
            print("po-leader algorithm: Using result: opt[1][" .. #notes ..
                                  "][1][" .. totalNumSlots .. "][" .. maxPlaced .. "]")

            print("resulting length: " .. length)
            print("resulting positions:")
            print(inspect(positions))
            print("resulting leaderShifts:")
            print(inspect(leaderShiftY))
            print("----------------")

            -- on page
            tex.print("\\node[text=blue,fill=white,rectangle,align=center] at (10.5cm,-27cm) {" ..
                "total length: " .. number.tocentimeters(length, "%s%s") .. "\\\\ " ..
                "rasterHeight: " .. number.tocentimeters(rasterHeight, "%s%s") ..
                "};")
        end

        for _, ind in pairs(notes) do
            local v = notesForPage[ind]
            v.outputX = area.left
            v.leaderShiftX = 0
            if positions[ind] == nil then
                print("did not define a position for note " .. v.index)
                v.outputY = 0
                v.leaderShiftY = 0
            else
                v.outputY = getRasterAbsolute(rasterHeight, area.top, positions[ind])
                if leaderShiftY[ind] ~= nil then
                    v.leaderShiftY = leaderShiftY[ind]
                end
            end
        end
    end
end
positioningAlgos["poLeaders"] = {algo = posPoLeaders,
    leaderAnchor = "east",
    leaderShift = false,
    twoSided = true}

local function posPoLeadersAvoid(notes, rightSide)
    posPoLeaders(notes, rightSide, true)
end
positioningAlgos["poLeadersAvoidLines"] = {algo = posPoLeadersAvoid,
    leaderAnchor = "east",
    leaderShift = true,
    twoSided = true,
    needLinePositions = true}




-- ********** Splitting Algorithms **********

-- ** splittingAlgorithm: none
-- place all notes on the wider side
local function splitNone()
    local rightSideSelected = false
    if labelArea.left == nil and labelArea.right == nil then
        error("Cannot place labels on any side of text (not enough space). " ..
            "Consider using the additionalMargin option of the package to " ..
            "extend the page margins " ..
            "or minNoteWidth to decrease the minimum width required")
    elseif labelArea.left == nil then
        rightSideSelected = true
    elseif labelArea.right ~= nil and
            labelArea.right.noteWidth > labelArea.left.noteWidth then
        rightSideSelected = true
    end

    for _, v in pairs(notesForPage) do
        v.rightSide = rightSideSelected
    end
end
splittingAlgos["none"] = {algo = splitNone}



-- ** splittingAlgorithm: middle
-- split on middle of page
local function splitMiddle()
    if labelArea:isOneSided() then
        splitNone()
    else
        local splitLine = (labelArea.text.right + labelArea.text.left)/2
        for _, v in pairs(notesForPage) do
            if v.inputX <= splitLine then
                v.rightSide = false
            else
                v.rightSide = true
            end
        end
    end
end
splittingAlgos["middle"] = {algo = splitMiddle}



-- ** splittingAlgorithm: median
-- split at median (sites sorted by x-coordinate)
local function splitMedian()
    if labelArea:isOneSided() then
        splitNone()
    else
        if #notesForPage == 0 then
            return
        end

        -- list that contains notes sorted by their inputX-coordinate
        local notesSorted = {}
        for _, v in pairs(notesForPage) do
            table.insert(notesSorted, v)
        end
        table.sort(notesSorted, compareNoteInputXAsc)

        local maxIndLeft
        if #notesSorted % 2 == 1 then
            maxIndLeft = math.ceil(#notesSorted / 2)
        else
            maxIndLeft = #notesSorted / 2
        end

        for k, v in pairs(notesSorted) do
            if k <= maxIndLeft then
                v.rightSide = false
            else
                v.rightSide = true
            end
        end
    end
end
splittingAlgos["median"] = {algo = splitMedian}



-- ** splittingAlgorithm: weightedMedian
-- split at weighted median (sites sorted by x-coordinate)
-- sum of heights of labels on both sides are similiar to each other
local function splitWeightedMedian()
    if labelArea:isOneSided() then
        splitNone()
    else
        if #notesForPage == 0 then
            return
        end

        -- list that contains notes sorted by their inputX-coordinate
        local notesSorted = {}
        for _, v in pairs(notesForPage) do
            table.insert(notesSorted, v)
        end
        table.sort(notesSorted, compareNoteInputXAsc)

        local heightLeft = 0
        local heightRight = 0
        while #notesSorted > 0 do
            if heightRight < heightLeft then
                -- place next note on the right side
                local note = notesSorted[#notesSorted]
                note.rightSide = true
                heightRight = heightRight + note:getHeight() + 2 * noteInnerSep + noteInterSpace
                table.remove(notesSorted, #notesSorted)
            else
                -- place next note on the left side
                local note = notesSorted[1]
                note.rightSide = false
                heightLeft = heightLeft + note:getHeight() + 2 * noteInnerSep + noteInterSpace
                table.remove(notesSorted, 1)
            end
        end
    end
end
splittingAlgos["weightedMedian"] = {algo = splitWeightedMedian}

