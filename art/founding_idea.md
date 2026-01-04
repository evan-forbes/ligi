# Ligi: Human and LLM Readable Project Managment, Note Taking, and Context Building

## Goals

- Replace obsidian document linking and "second brain" capabilities
- Replace github's project managment
- Add repo specific context building for AI agents

## Implementation

all markdown documents are kept per repo in `art/` (art being short for artifacts fwiw).

there are special directories in `art/` for indexes, templates, archive, and configurations
`art/index`, `art/template`, `art/config`, `art/archive`

there is a local global high level index which keeps track of everything in the ~/.ligi/art/

**when calling `ligi init` all of these need to be created if they are not already**

this ofc also has index and template directories there. this art/ is special in that it is global and can be read from by all other repo specific artifacts

while there is a global art/ per above, there is a local art per repo. this and the special directories are also created when calling `ligi init`

### Indexing

ligi itself is just a cli tool for managing and maintaining human readable indexes. This is paired with a non-breaking addition(s) to markdown that the user can use to indicate where and which links need to be created between documents.

#### Tagging

There should be a wiki link esque tag [[t/tag_name]] (or similar whatever is standard). All known tags are maintained in art/index/ligi_tags.md, which is a document that has a list of all tags and links to the index file for that tag.

ligi can be ran anytime after that tag is added to a document, in which case ligi keeps track of that tag in a new index. 

#### Linking

ligi also recognizes linking to other documents directly as well. most of the time, this will just be another document in the art/ directory, but could be any document including a "special" one in the special directories. links are simply normal markdown links! There doesn't need to be anything special about them. ligi can recognize if it can find that object that is linked. If it can, then it keeps track of those links similar to a graph database, meaning that it has a separate doc in art/index that lists all of the links between a specific file. meaning for each file created by the user in art/, there is an index file also created in art/index/links_file_name.md. This file keeps track of the references to that file. This is for easy backlinking that avoids querying the entire set of a notes to find all backwards. It also keeps track of all the links in the existing links in that file to other documents for easy access

the command:
`ligi i (alias for index) (-r aka --root defaults to .) (-f --file path to the file. if none provided assume all files *)`

from within a repo will quickly add new links that are missing. how this is done as fast as possible is tbd. it also must be easy to add to helix upon saving or closing a markdown file that is passed to -f.

tags [[t/...]] each have their own index file that keeps track of documents that have those tags

#### edge cases

when indexing links, the only files that we can't index are files that are index files.

## Cleanup

`ligi a (alias for archive)`

only used as a "recycle" or "trash" bin. links need to be modified to point to the archived document. This should be done rarely. If a document is no longer relevant then outdated tags or some other tag could be added instead

## Queries

since ligi notes are just markdown files, any existing search mechanism over files works out of the box. This is includes grep or fzf. Using these tools as much as possible is preferred over re-implementing them here. There are some queries however that ligi can do better because it is aware of the ligi schema (a bunch of arbitrarily linked documents)

### Tags

one of the most used organizational tools for ligi is tags. We need to be able to list all documents from a given tag

`ligi q (alias for query) t (alias for tag) tag_name`

this returns all of the files that have that tag. Note that while we have the index to quickly return, we also need to check if indexing of this tag is needed. If the index is not entirely up to date, then it should be indexed before searching for that tag. This presumably is using something like ripgrep for super fast searching of instances of the files that have that tag.

we also have the ability to add & and | for `and` and `or` operators specifically.

the output is simply the file path from the root of the directory. (not that there should be a flag -a --absolute to indicate that the full path should be returns) (note that there is an -o --output flag that can indicate json ("tag":["path",]))

```sh
art/file_1.md
art/file_2.md
art/file_n.md
```

there is a also a flag -c --clipboard which is by default false and will copy the output to the clipboard.i

## Templates

Templates are used for filling in usecase specific details for prompts, or creating specific reports etc. There is an existing tool that can be used here in a different repo. We might end up merging the tools.

## Git

Of course, ligi artifacts bake directly into the version of each repo, which is presumed to be git. The global ligi repo also has is own git repo. One way of initializing ligi globally or in a local repo is simply via cloning a repo via git!














