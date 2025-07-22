#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 0. Global build flags
###############################################################################
# Linux needs the metadata kept alive **and** exported from the shared library.
if [[ "$(uname)" != "Darwin" ]]; then
  export RUSTFLAGS="-C link-arg=-Wl,--export-dynamic -C link-arg=-Wl,--no-gc-sections"
fi
# Prevent Cargo’s `[profile.release] strip = true` from removing the symbols
export CARGO_PROFILE_RELEASE_STRIP=none

###############################################################################
# 1. Paths & helpers
###############################################################################
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINDINGS="$ROOT/bindings/kotlin"
OUT_LIBMODULE="$ROOT/out/PolkabindKotlin"
OUT_PKG="$ROOT/out/polkabind-kotlin-pkg"

case "$(uname)" in
  Darwin) EXT=dylib;  NM="nm -gU" ;;  # Mach-O
  *)      EXT=so;     NM="nm -D --defined-only" ;;  # ELF
esac
RUST_DYLIB="$ROOT/target/release/libpolkabind.$EXT"

###############################################################################
# 1.½  (NEW) portable ELF-stripper for the Android .so’s
###############################################################################
strip_elf() {
  local f=$1
  # Prefer llvm-strip from the NDK (works on macOS & Linux)
  if [[ -n "${ANDROID_NDK_HOME:-}" ]] && \
     tool=$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip) && \
     [[ -x $tool ]]; then
    "$tool" --strip-unneeded "$f"
    return
  fi
  # GNU strip on Linux hosts
  if [[ "$(uname)" == "Linux" ]]; then
    strip --strip-unneeded "$f"
    return
  fi
  # Otherwise: keep symbols (macOS without NDK llvm-strip)
  echo "⚠️  cannot strip $(basename "$f") – keeping symbols"
}

###############################################################################
# 2. Build the entire workspace once
###############################################################################
echo "🔨 Building workspace (host tools + dylib)…"
cargo build --release --workspace

UNIFFI_BIN="$ROOT/target/release/uniffi-bindgen"
[[ -x "$UNIFFI_BIN" ]] || { echo "❌ uniffi-bindgen missing"; exit 1; }

echo "bindgen version     : $("$UNIFFI_BIN" --version)"
echo "host dylib produced : $RUST_DYLIB"

# Quick sanity-check that metadata is present
echo -e "\nUniFFI symbols in host dylib:"
if ! $NM "$RUST_DYLIB" | grep -q UNIFFI_META_NAMESPACE_; then
  echo "❌ UniFFI metadata NOT found; the dylib would be stripped."
  exit 1
fi
$NM "$RUST_DYLIB" | grep UNIFFI_META | head

###############################################################################
# 3. Generate Kotlin bindings
###############################################################################
echo -e "\n🧹 Generating Kotlin bindings…"
rm -rf "$BINDINGS" && mkdir -p "$BINDINGS"

"$UNIFFI_BIN" generate \
  --config   "$ROOT/uniffi.toml" \
  --no-format \
  --library  "$RUST_DYLIB" \
  --language kotlin \
  --out-dir  "$BINDINGS"

GLUE_SRC="$BINDINGS/dev/polkabind/polkabind.kt"
[[ -f "$GLUE_SRC" ]] || { echo "❌ polkabind.kt absent"; exit 1; }

###############################################################################
# 4. Cross-compile Rust for the Android ABIs   (now stripped afterwards)
###############################################################################
ABIS=(arm64-v8a armeabi-v7a)
echo -e "\n🛠️  Building Android .so files…"
for ABI in "${ABIS[@]}"; do
  case $ABI in
    arm64-v8a)   TARGET=aarch64-linux-android ;;
    armeabi-v7a) TARGET=armv7-linux-androideabi ;;
  esac

  cargo ndk --target "$TARGET" --platform 21 build --release
  SO="$ROOT/target/${TARGET}/release/libpolkabind.so"
  [[ -f "$SO" ]] || { echo "❌ .so for $TARGET missing"; exit 1; }

  # ──► optimisation bit
  strip_elf "$SO"
  echo "   • $(basename "$SO") size ⇒ $(du -h "$SO" | cut -f1)"
done

###############################################################################
# 5. Lay out a minimal Android library module
###############################################################################
echo -e "\n📂 Preparing Android library module…"
MODULE_DIR="$OUT_LIBMODULE/polkabind-android"
rm -rf "$MODULE_DIR"
mkdir -p "$MODULE_DIR/src/main/java/dev/polkabind"

# -- glue
cp "$GLUE_SRC" "$MODULE_DIR/src/main/java/dev/polkabind/"

# -- jniLibs
for ABI in "${ABIS[@]}"; do
  mkdir -p "$MODULE_DIR/src/main/jniLibs/$ABI"
  case $ABI in
    arm64-v8a)   TARGET=aarch64-linux-android ;;
    armeabi-v7a) TARGET=armv7-linux-androideabi ;;
  esac
  cp "$ROOT/target/${TARGET}/release/libpolkabind.so" \
     "$MODULE_DIR/src/main/jniLibs/$ABI/"
done

# -- Gradle files
cat >"$MODULE_DIR/settings.gradle.kts" <<'EOF'
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
    plugins {
        id("com.android.library") version "8.4.0"
        kotlin("android")         version "1.9.20"
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "polkabind-android"
EOF

cat >"$MODULE_DIR/build.gradle.kts" <<'EOF'
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

group = "dev.polkabind"
version = findProperty("releaseVersion") as String

plugins {
    id("com.android.library")
    kotlin("android")
    id("maven-publish")
}

dependencies {
    implementation("net.java.dev.jna:jna:5.13.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.6.4")
}

android {
    namespace  = "dev.polkabind"
    compileSdk = 35
    defaultConfig {
        minSdk = 24
        ndk { abiFilters += listOf("arm64-v8a","armeabi-v7a") }
    }
    publishing { singleVariant("release") }
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
}

afterEvaluate {
    publishing.publications.create<MavenPublication>("release") {
        groupId    = "dev.polkabind"
        artifactId = "polkabind-android"
        version    = "1.0.0-SNAPSHOT"
        from(components["release"])
    }
}

publishing {
  publications {
    create<MavenPublication>("release") {
      from(components["release"])
      // these match group & version above
      groupId    = project.group.toString()
      artifactId = "polkabind-android"
      version    = project.version.toString()
    }
  }
  repositories {
    maven {
      name = "GitHubPackages"
      url  = uri("https://maven.pkg.github.com/Polkabind/polkabind-kotlin-pkg")
      credentials {
        username = providers.environmentVariable("GITHUB_ACTOR")
        password = providers.environmentVariable("GITHUB_TOKEN")
      }
    }
  }
}

tasks.withType<KotlinCompile>().configureEach {
    kotlinOptions.jvmTarget = "1.8"
}
EOF

###############################################################################
# 6. Build the AAR
###############################################################################
echo -e "\n🔧 Building AAR…"
pushd "$MODULE_DIR" >/dev/null
[[ -f gradlew ]] || gradle wrapper --gradle-version 8.6 --distribution-type all
./gradlew -q clean bundleReleaseAar
popd >/dev/null

###############################################################################
# 7. Assemble distributable package
###############################################################################
echo -e "\n🚚 Bundling Kotlin package…"
rm -rf "$OUT_PKG" && mkdir -p "$OUT_PKG"
cp "$ROOT/LICENSE" "$OUT_PKG/"
cp "$ROOT/docs/readmes/kotlin/README.md" "$OUT_PKG/"
cp -R "$MODULE_DIR/build/outputs/aar" "$OUT_PKG/aar"
cp -R "$MODULE_DIR/src/main/java/dev/polkabind" "$OUT_PKG/src"

echo -e "\n✅ Success!  Kotlin package → $OUT_PKG"

###############################################################################
# 8. Layout Maven like package
###############################################################################
# Emit a POM file alongside the AAR
VERSION=${GITHUB_REF_NAME#v}
GROUP=dev.polkabind
ARTIFACT=polkabind-android

OUT_RELEASES="$ROOT/out/polkabind-kotlin-pkg/releases/$GROUP/$ARTIFACT/$VERSION"
mkdir -p "$OUT_RELEASES"
cp "$MODULE_DIR/build/outputs/aar/$ARTIFACT-release.aar" \
   "$OUT_RELEASES/$ARTIFACT-$VERSION.aar"

# generate a minimal POM:
cat >"$OUT_RELEASES/$ARTIFACT-$VERSION.pom" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${GROUP}</groupId>
  <artifactId>${ARTIFACT}</artifactId>
  <version>${VERSION}</version>
  <packaging>aar</packaging>
</project>
EOF

# generate maven-metadata.xml
METADATA_DIR="$ROOT/out/polkabind-kotlin-pkg/releases/$GROUP/$ARTIFACT"
cd "$METADATA_DIR"
# collect all versions
VERSIONS=($(ls -1d */))
cat > maven-metadata.xml <<EOF
<metadata>
  <groupId>${GROUP}</groupId>
  <artifactId>${ARTIFACT}</artifactId>
  <versioning>
    <latest>${VERSION}</latest>
    <release>${VERSION}</release>
    <versions>
$(for v in "${VERSIONS[@]}"; do
     echo "      <version>${v%/}</version>"
   done)
    </versions>
    <lastUpdated>$(date -u +'%Y%m%d%H%M%S')</lastUpdated>
  </versioning>
</metadata>
EOF
