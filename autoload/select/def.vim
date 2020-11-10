""" Select definitions

let s:select = {}

func! select#def#get()
    return s:select
endfunc


"""
""" Select file
"""
let s:select.file = {}
let s:select.file.data = {path ->
            \  map(readdirex(path, {d -> d.type =~ '\%(dir\|linkd\)$'}), {_, v -> v.name..'/'})
            \+ map(readdirex(path, {d -> d.type =~ '\%(file\|link\)$'}), {_, v -> v.name})
            \ }
let s:select.file.sink = {
            \ "transform": {p, v -> fnameescape(p..v)},
            \ "empty": {v -> v},
            \ "special": {state, val -> s:special_visit_directory(state, val)},
            \ "action_new": "edit %s",
            \ "action": "edit %s",
            \ "action2": "split %s",
            \ "action3": "vsplit %s",
            \ "action4": "tab split %s"
            \ }
let s:select.file.highlight = {"Directory": ['^.*/$', 'Directory']}
let s:select.file.prompt = "File> "


"""
""" Select projectfile
"""
let s:select.projectfile = {}
if executable('fd')
    let s:select.projectfile.data = {"cmd": "fd --type f --hidden --follow --no-ignore-vcs --exclude .git"}
elseif executable('fdfind')
    let s:select.projectfile.data = {"cmd": "fdfind --type f --hidden --follow --no-ignore-vcs --exclude .git"}
elseif executable('rg')
    let s:select.projectfile.data = {"cmd": "rg --files --no-ignore-vcs --hidden --glob !.git"}
elseif !has("win32")
    let s:select.projectfile.data = {"cmd": "find -type f -not -path \"*/.git/*\""}
else
    let s:select.projectfile.data = ""
endif
let s:select.projectfile.sink = {
            \ "transform": {p, v -> fnameescape(p..v)},
            \ "special": {state, val -> s:special_save_project(state, val)},
            \ "action": "edit %s",
            \ "action2": "split %s",
            \ "action3": "vsplit %s",
            \ "action4": "tab split %s"
            \ }
let s:select.projectfile.highlight = {"DirectoryPrefix": ['\(\s*\d\+:\)\?\zs.*[/\\]\ze.*$', 'Comment']}
let s:select.projectfile.prompt = "Project File> "


"""
""" Select mru
"""
let s:select.mru = {}
let s:select.mru.data = {-> filter(copy(v:oldfiles), {_,v -> filereadable(expand(v))})}
let s:select.mru.sink = {"transform": {_, v -> fnameescape(v)},
            \ "action": "edit %s",
            \ "action2": "split %s",
            \ "action3": "vsplit %s",
            \ "action4": "tab split %s"
            \ }
let s:select.mru.highlight = {"DirectoryPrefix": ['\(\s*\d\+:\)\?\zs.*[/\\]\ze.*$', 'Comment']}


"""
""" Select buffer
"""
let s:select.buffer = {}
let s:select.buffer.data = {-> s:get_buffer_list()}
let s:select.buffer.sink = {"transform": {_, v -> matchstr(v, '^\s*\zs\d\+')},
            \ "action": "buffer %s",
            \ "action2": "sbuffer %s",
            \ "action3": "vert sbuffer %s",
            \ "action4": "tab sbuffer %s"
            \ }
let s:select.buffer.highlight = {
            \ "DirectoryPrefix": ['\(\s*\d\+:\)\?\zs.*[/\\]\ze.*$', 'Comment'],
            \ "PrependBufNr": ['^\(\s*\d\+:\)', 'Identifier']
            \ }


"""
""" Select colors
"""
let s:select.colors = {}
let s:select.colors.data = {-> s:get_colorscheme_list()}
let s:select.colors.sink = "colorscheme %s"


"""
""" Select command
"""
let s:select.command = {}
let s:select.command.data = {-> getcompletion('', 'command')}
let s:select.command.sink = {"action": {v -> feedkeys(':'..v, 'n')}}


"""
""" Select project
"""
let s:select.project = {}
let s:select.project.data = {-> s:get_project_list()}
let s:select.project.sink = {"action": "Select projectfile %s", "action2": "Select file %s"}
let s:select.project.highlight = {"DirectoryPrefix": ['\(\s*\d\+:\)\?\zs.*[/\\]\ze.*$', 'Comment']}


"""
""" Select help
"""
let s:select.help = {}
let s:select.help.data = {"cmd": {-> s:get_helptags()}}
let s:select.help.sink = "help %s"


"""
""" Select bufline
"""
let s:select.bufline = {}
let s:select.bufline.data = {_, v ->
            \ getbufline(v.bufnr, 1, "$")->map({i, ln -> printf("%*d: %s", len(line('$', v.winid)), i+1, ln)})
            \ }
let s:select.bufline.sink = {
            \ "transform": {_, v -> matchstr(v, '^\s*\zs\d\+')},
            \ "action": "normal %sG"
            \ }
let s:select.bufline.highlight = {"PrependLineNr": ['^\(\s*\d\+:\)', 'LineNr']}



"""
""" Helpers
"""

"" Buffer list is sorted by lastused time + 2 most recently used buffers
"" are exchanged/switched:
"" * second lastused is the first in the list
"" * first lastused is the second in the list
"" Thus you can easily switch between 2 buffers with :Select buffer and <CR>
func! s:get_buffer_list() abort
    let l:Sort = {a, b -> a.lastused == b.lastused ? 0 : a.lastused > b.lastused ? -1 : 1}
    let buflist = sort(getbufinfo({'buflisted': 1}), l:Sort)
    return map(buflist[1:1] + buflist[0:0] + buflist[2:], {k, v -> printf("%3d: %s", v.bufnr, (empty(v.name) ? "[No Name]" : v.variables->has_key("netrw_browser_active") ? substitute(v.name, '\\\+', '/', 'g')..'/' : substitute(fnamemodify(v.name, ":p:."), '\\\+', '/', 'g')))})
endfunc


"" Colorscheme list.
"" * remove current colorscheme name  from the list of all sorted colorschemes.
"" * put current colorscheme name on top of the colorscheme list.
"" Thus current colorscheme is initially preselected.
func! s:get_colorscheme_list() abort
    let colors_name = get(g:, "colors_name", "default")
    return [colors_name] + filter(getcompletion('', 'color'), {_, v -> v != colors_name})
endfunc


"" List of all help tags/topics.
"" Uses ripgrep.
func! s:get_helptags() abort
    let l:help = split(globpath(&runtimepath, 'doc/tags', 1), '\n')
    return 'rg ^[^[:space:]]+ -No --no-heading --no-filename '..join(map(l:help, {_,v -> fnameescape(v)}))
endfunc


"" Project list.
"" List of current working directories where :Select projectfile was run.
func! s:get_project_list() abort
    try
        let fname = fnamemodify(expand("$MYVIMRC"), ":p:h").."/.selectprojects"
        return readfile(fname)
    catch
        return []
    endtry
endfunc


"" Handle special case for Select projectfile.
"" When you a file in Select projectfile, current working directory should be
"" saved in .selectprojects
"" Always return false (closes Select window)
func! s:special_save_project(state, val)
    let project = trim(a:state.path, "/", 2)
    let projects = s:get_project_list()
    let projects = [project] + filter(projects, {_, v -> v != project})
    try
        let fname = fnamemodify(expand("$MYVIMRC"), ":p:h").."/.selectprojects"
        call writefile(projects, fname)
    catch
    endtry

    return v:false
endfunc


"" Handle special case for Select file.
"" When you Select file which is a directory it should visit it instead of opening.
"" If result is true --> Select window should not be closed
func! s:special_visit_directory(state, val)
    if !isdirectory(a:state.path..a:val)
        return v:false
    endif

    let a:state.path = a:state.path..a:val
    call setbufline(a:state.prompt_buf.bufnr, '$', '')
    call win_execute(a:state.result_buf.winid, 'normal! gg')
    let a:state.cached_items = []
    return v:true
endfunc
