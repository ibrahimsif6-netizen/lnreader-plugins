
#!/bin/bash

if [ -z "$GITHUB_STEP_SUMMARY" ]; then
    GITHUB_STEP_SUMMARY="/dev/stdout"
fi

set -e

current=$(git rev-parse --abbrev-ref HEAD)
version=$(node -e "console.log(require('./package.json').version);")
dist="plugins/v$version"

echo "Publishing plugins: $current -> $dist (v$version)"

if [[ "$1" == "--all-branches" ]]; then
    rm -rf .dist .js
    git fetch --all

    # Process compatible source branches, with patch-1 last.
    mapfile -t branches < <(
        git branch -r |
        sed 's/^[* ]*//' |
        grep -v '\->' |
        grep -v '/patch-1$' |
        sort
    )

    if git show-ref --verify --quiet refs/remotes/origin/patch-1; then
        branches+=("origin/patch-1")
    fi

    for branch in "${branches[@]}"; do
        # Published branches contain build artifacts, not source scripts.
        if ! git cat-file -e "$branch:scripts/publish-plugins.sh" 2>/dev/null; then
            echo "Skipping $branch (publish script not present)"
            continue
        fi

        if ! diff -q scripts/publish-plugins.sh \
            <(git show "$branch:scripts/publish-plugins.sh") >/dev/null; then
            echo "Skipping $branch (script version mismatch)"
            continue
        fi

        echo "::group::Branch $branch"
        echo "Processing: $branch"

        # Preserve generated files between source branches.
        git stash push -a -- .dist .js || {
            echo "ERROR: Failed to stash generated files"
            exit 1
        }

        git checkout -f "$branch"

        if git stash list -1 | grep -q .; then
            git stash pop || {
                echo "ERROR: Failed to restore generated files"
                exit 1
            }
        fi

        npm run clean:multisrc
        npm run build:multisrc

        echo "Compiling TypeScript..."
        npx tsc --project tsconfig.production.json

        echo "# $branch" >> "$GITHUB_STEP_SUMMARY"

        BRANCH="$dist" npm run build:manifest -- --only-new \
            2>> "$GITHUB_STEP_SUMMARY"

        if [ ! -d ".dist" ] || [ -z "$(ls -A .dist)" ]; then
            echo "ERROR: Manifest generation failed"
            exit 1
        fi

        echo "Done: $branch"
        echo "::endgroup::"
    done

    echo "::group::Publish All Branches"
    echo "Publishing combined plugins..."

    # Ensure the destination branch can be recreated.
    git checkout -f "$current"

    if git show-ref --verify --quiet "refs/heads/$dist"; then
        git branch -D "$dist"
    fi

    git checkout --orphan "$dist"
    git reset

    echo "Copying .js/plugins -> .js/src/plugins"
    mkdir -p .js/src

    if [ ! -d ".js/plugins" ]; then
        echo "ERROR: .js/plugins is missing"
        exit 1
    fi

    cp -r .js/plugins .js/src/plugins

    git add -f public/static .dist .js/src/plugins total.svg
    git commit -m "chore: Publish Plugins From All Branches"
    git push -f origin "$dist"

    git checkout -f "$current"

    echo "Published all branches to $dist"
    echo "::endgroup::"
    exit 0
fi

if git show-ref --verify --quiet "refs/heads/$dist"; then
    git branch -D "$dist"
fi

git checkout --orphan "$dist"
git reset
rm -rf .js

npm run clean:multisrc
npm run build:multisrc

echo "Compiling TypeScript..."
npx tsc --project tsconfig.production.json

npm run build:manifest

if [ ! -d ".dist" ] || [ -z "$(ls -A .dist)" ]; then
    echo "ERROR: Manifest generation failed"
    exit 1
fi

echo "Copying .js/plugins -> .js/src/plugins"
mkdir -p .js/src

if [ ! -d ".js/plugins" ]; then
    echo "ERROR: .js/plugins is missing"
    exit 1
fi

cp -r .js/plugins .js/src/plugins

git add -f public/static .dist .js/src/plugins total.svg
git commit -m "chore: Publish Plugins"
git push -f origin "$dist"

git checkout -f "$current"
echo "Published to $dist"
