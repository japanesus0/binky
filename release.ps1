# release.ps1 — one-shot release pipeline for binky.
#
# Usage (from the repo root, D:\ProjectFiles\Binky\binky\):
#
#   .\release.ps1            Builds locally end-to-end. Use this when
#                            you DON'T have the GitHub Actions cloud build
#                            configured (or you specifically want a local
#                            AAB).
#
#   .\release.ps1 -NoBuild   Bumps versionCode, commits, pushes. Stops
#                            before the local build, because CI will
#                            build the AAB in the cloud (see
#                            .github/workflows/build.yml). Download the
#                            resulting AAB from the Actions tab.
#
# What it does (each step gates on the previous succeeding — any failure
# stops the pipeline before pushing, so the repo never ends up in a
# half-released state):
#
#   1. Verify the working tree is clean.
#   2. Sync `main` from origin.
#   3. Bump versionCode in app/pubspec.yaml (the +N suffix; +N+1).
#   4. (Default) Build the release AAB locally.
#   5. Commit the bump and push.
#   6. Tell you what to do next (upload to Play Console).
#
# If the local build fails (step 4), the versionCode bump is reverted
# automatically so you can re-run from a clean state.

param(
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

function Step($n, $text) {
    Write-Host ""
    Write-Host "[$n] $text" -ForegroundColor Cyan
}
function Die($msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

# 0. Sanity: we're at the project root.
if (-not (Test-Path "app/pubspec.yaml")) {
    Die "Run from the repo root (where app/pubspec.yaml lives)."
}

# 1. Working tree must be clean.
Step 1 "Checking working tree is clean..."
$dirty = git status --porcelain
if ($dirty) {
    Write-Host "Uncommitted changes:" -ForegroundColor Yellow
    Write-Host $dirty
    Die "Working tree must be clean. Commit or stash first."
}
Write-Host "  Clean." -ForegroundColor Green

# 2. Sync main from origin.
Step 2 "Syncing main from origin..."
git checkout main
if ($LASTEXITCODE -ne 0) { Die "git checkout main failed" }
git pull --ff-only
if ($LASTEXITCODE -ne 0) { Die "git pull failed (history diverged? not fast-forwardable?)" }

# 3. Bump versionCode.
Step 3 "Bumping versionCode in app/pubspec.yaml..."
$pubspecPath = "app/pubspec.yaml"
$content = Get-Content $pubspecPath -Raw
if ($content -notmatch '(?m)^version:\s+(\d+\.\d+\.\d+)\+(\d+)\s*$') {
    Die "Couldn't find the 'version: X.Y.Z+N' line in pubspec.yaml"
}
$semver = $matches[1]
$oldBuild = [int]$matches[2]
$newBuild = $oldBuild + 1
$oldVersion = "${semver}+${oldBuild}"
$newVersion = "${semver}+${newBuild}"
$content = $content -replace "(?m)^version:\s+${semver}\+${oldBuild}\s*$", "version: ${newVersion}"
Set-Content -Path $pubspecPath -Value $content -NoNewline -Encoding utf8
Write-Host "  ${oldVersion}  ->  ${newVersion}" -ForegroundColor Green

# 4. Build locally (unless skipped). If the build fails, revert the bump
#    so the next run starts from a clean state.
if (-not $NoBuild) {
    Step 4 "Building release AAB locally (this takes a few minutes)..."
    Push-Location app
    try {
        flutter clean
        if ($LASTEXITCODE -ne 0) { throw "flutter clean failed" }
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
        flutter build appbundle --release --obfuscate --split-debug-info=build\symbols
        if ($LASTEXITCODE -ne 0) { throw "flutter build appbundle failed" }
    }
    catch {
        Pop-Location
        Write-Host "Build failed — reverting versionCode bump..." -ForegroundColor Yellow
        git checkout app/pubspec.yaml | Out-Null
        Die "Build pipeline failed: $($_.Exception.Message)"
    }
    Pop-Location
}
else {
    Step 4 "Skipping local build (-NoBuild). GitHub Actions will build in the cloud."
}

# 5. Commit + push the bump.
Step 5 "Committing version bump and pushing..."
git add app/pubspec.yaml
git commit -m "chore: bump versionCode to ${newVersion}"
if ($LASTEXITCODE -ne 0) { Die "git commit failed" }
git push
if ($LASTEXITCODE -ne 0) {
    Die "git push failed. Your local commit is fine; push manually with 'git push' once the issue is resolved."
}

# 6. Done — tell user where the AAB is (or where to find it).
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " Release ${newVersion} prepared on origin/main" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

if (-not $NoBuild) {
    $aabPath = "app/build/app/outputs/bundle/release/app-release.aab"
    $aabFull = (Resolve-Path $aabPath).Path
    $aabSizeKB = [math]::Round((Get-Item $aabPath).Length / 1KB, 0)
    Write-Host "AAB:    $aabFull"
    Write-Host "Size:   $aabSizeKB KB"
}
else {
    Write-Host "AAB will be built in GitHub Actions. Once the workflow completes:"
    Write-Host "  1. Open https://github.com/japanesus0/binky/actions"
    Write-Host "  2. Click the latest 'build' run on main"
    Write-Host "  3. Download the 'binky-aab-<sha>' artifact"
    Write-Host "  4. Extract the .aab file from the zip"
}

Write-Host ""
Write-Host "Then upload to Play Console:"
Write-Host "  1. Testing -> Closed testing -> [your track] -> Create new release"
Write-Host "  2. Upload the AAB"
Write-Host "  3. Add release notes"
Write-Host "  4. Review release -> Start rollout"
Write-Host ""
