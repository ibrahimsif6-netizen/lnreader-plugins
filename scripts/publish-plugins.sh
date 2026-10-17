
#!/bin/bash



if [ -z "$GITHUB_STEP_SUMMARY" ]; then
    GITHUB_STEP_SUMMARY="/dev/stdout"
fi

current=$(git rev-parse --abbrev-ref HEAD)
version=$(node -e "console.log(require('./package.json').version);")
dist="plugins/v$version"

echo "Publishing plugins: $current -> $dist (v$version)"

if [[ "$1" == "--all-branches" ]]; then
    rm -rf .dist .js
    git fetch --all

    # Process patch-1 last so its plugin builds take precedence
    # when the same plugin exists on multiple branches.
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
        # The published branch contains build artifacts, not the
        # publishing script, so it is intentionally skipped.
        if ! git cat-file -e "$branch:scripts/publish-plugins.sh" 2>/dev/null; then
            echo "⚠️ Skipping $branch (publish script not present)"
            continue
        fi

        if ! diff -q scripts/publish-plugins.sh \
            <(git show "$branch:scripts/publish-plugins.sh") >/dev/null; then
            echo "⚠️ Skipping $branch (script version mismatch)"
            continue
        fi

        echo "::group::Branch $branch"
        echo "Processing: $branch"

        git stash push -a -- .dist .js || exit 1
        git checkout -f "$branch" || exit 1

        exists=$(git show-ref "refs/heads/$dist")
        if [ -n "$exists" ]; then
            git branch -D "$dist"
        fi

        git stash pop || {
            echo "❌ ERROR: Failed to restore generated files"
            exit 1
        }

        npm run clean:multisrc || exit 1
        npm run build:multisrc || exit 1

        echo "Compiling TypeScript..."
        npx tsc --project tsconfig.production.json || exit 1

        echo "# $branch" >> "$GITHUB_STEP_SUMMARY"

        BRANCH="$dist" npm run build:manifest -- --only-new \
            2>> "$GITHUB_STEP_SUMMARY" || exit 1

        if [ ! -d ".dist" ] || [ -z "$(ls -A .dist)" ]; then
            echo "❌ ERROR: Manifest generation failed - .dist is missing or empty"
            exit 1
        fi

        echo "✅ Done: $branch"
        echo "::endgroup::"
    done

    echo
    echo "::group::Publish All Branches"
    echo "Publishing combined plugins..."

    git checkout --orphan "$dist" || {
        echo "❌ ERROR: Failed to create branch $dist"
        exit 1
    }

    git reset

    echo "Copying .js/plugins -> .js/src/plugins"
    mkdir -p .js/src

    if [ -d ".js/plugins" ]; then
        cp -r .js/plugins .js/src/plugins
    else
        echo "❌ ERROR: .js/plugins is missing"
        exit 1
    fi

    git add -f public/static .dist .js/src/plugins total.svg || exit 1

    git commit -m "chore: Publish Plugins From All Branches" || exit 1
    git push -f origin "$dist" || exit 1

    git checkout -f "$current" || exit 1

    echo "✅ Published all branches to $dist"
    echo "::endgroup::"
    exit 0
fi

exists=$(git show-ref "refs/heads/$dist")
if [ -n "$exists" ]; then
    git branch -D "$dist"
fi

git checkout --orphan "$dist" || {
    echo "❌ ERROR: Failed to create branch $dist"
    exit 1
}

git reset
rm -rf .js

npm run clean:multisrc || exit 1
npm run build:multisrc || exit 1

echo "Compiling TypeScript..."
npx tsc --project tsconfig.production.json || exit 1

npm run build:manifest || exit 1

if [ ! -d ".dist" ] || [ -z "$(ls -A .dist)" ]; then
    echo "❌ ERROR: Manifest generation failed - .dist is missing or empty"
    exit 1
fi

echo "Copying .js/plugins -> .js/src/plugins"
mkdir -p .js/src

if [ -d ".js/plugins" ]; then
    cp -r .js/plugins .js/src/plugins
else
    echo "❌ ERROR: .js/plugins is missing"
    exit 1
fi

git add -f public/static .dist .js/src/plugins total.svg || exit 1
git commit -m "chore: Publish Plugins" || exit 1
git push -f origin "$dist" || exit 1

git checkout -f "$current" || exit 1
echo "✅ Published to $dist"
