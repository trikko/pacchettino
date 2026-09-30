#!/bin/sh
# Generate the html documentation in docs/ (served by GitHub Pages) with scod, the same skin
# as serverino, parserino and jape, with the declarations (Pacchettino, UUIDv7, ...) in the
# menu on the left.
# docs/llms.txt, docs/llms-full.txt and docs/AGENTS.md are written by hand; docs/SKILL.md is
# generated from AGENTS.md.
# Usage: tools/docs.sh
set -e
cd "$(dirname "$0")/.."

dub build -q -b ddox
dub run -q scod -- generate-html --navigation-type=DeclarationTree \
    --sitemap-url=https://trikko.github.io/pacchettino/ docs.json docs
rm -f docs.json __dummy.html

# served as they are: without this Jekyll turns SKILL.md, which has front matter, into html
touch docs/.nojekyll

# SKILL.md is AGENTS.md with the front matter that makes it an installable skill
{
    printf -- '---\nname: pacchettino\n'
    printf 'description: Official reference for pacchettino, the file-based job queue for the D programming language (producers and consumers across processes and threads, crash recovery, delayed jobs, retries, status tracking). Use it whenever the user asks about pacchettino, or about job queues, background jobs or work queues in D.\n'
    printf -- '---\n\n'
    cat docs/AGENTS.md
} > docs/SKILL.md
echo "docs/ updated"
