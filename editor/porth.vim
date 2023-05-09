" Vim syntax file
" Language: Porth

if exists("b:current_syntax")
  finish
endif

syntax keyword porthTodo TODO XXX FIXME NOTE

syntax keyword porthKeyword if else end while do macro include

syntax region porthCommentLine start="//" end="$" contains=porthTodo

syntax region porthString start=/\v"/ skip=/\v\\./ end=/\v"/
syntax region porthString start=/\v'/ skip=/\v\\./ end=/\v'/

highlight default link porthTodo Todo
highlight default link porthKeyword Identifier
highlight default link porthCommentLine Comment
highlight default link porthString String

let b:current_syntax = "porth"
