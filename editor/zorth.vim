" Vim syntax file
" Language: Zorth

if exists("b:current_syntax")
    finish
endif

syntax keyword zorthTodo TODO XXX FIXME NOTE BUG

syntax keyword zorthKeyword if else end while do macro include

syntax region zorthCommentLine start="//" end="$" contains=zorthTodo

syntax region zorthString start=/\v"/ skip=/\v\\./ end=/\v"/
syntax region zorthString start=/\v'/ skip=/\v\\./ end=/\v'/

highlight default link zorthTodo Todo
highlight default link zorthKeyword Keyword
highlight default link zorthCommentLine Comment
highlight default link zorthString String

let b:current_syntax = "zorth"
