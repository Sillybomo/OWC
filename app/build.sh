#!/bin/bash
# @author bomo
# OWC App 构建脚本 — 零 gradle 手工构建链（aapt2 → javac → d8 → zipalign → apksigner）
# 依赖：D:/Software/Android（SDK）、D:/Software/Java17（JDK17）
# 中间产物：TMP 目录（不污染项目目录）；最终产物：OWCApp/owc-app-debug.apk

set -e
SDK="D:/Software/Android"
BT="$SDK/build-tools/35.0.0"
AJ="$SDK/platforms/android-36/android.jar"
JAVAC="D:/Software/Java17/jdk-17.0.12_windows-x64_bin/bin/javac.exe"
KEYTOOL="D:/Software/Java17/jdk-17.0.12_windows-x64_bin/bin/keytool.exe"
PROJ="$(cygpath -m "$(cd "$(dirname "$0")" && pwd)")"   # aapt2/d8 是 Windows 程序，需 D:/ 风格路径
TMP="$(cygpath -m "D:/Study/workspace/magisk/KernelSU_bugreport_2026-08-13_19_39.tar/tmp/owc_build")"
KEYSTORE="$PROJ/owc.keystore"

rm -rf "$TMP"; mkdir -p "$TMP/gen" "$TMP/classes" "$TMP/dex"

echo "[1/7] aapt2 compile"
"$BT/aapt2.exe" compile --dir "$PROJ/res" -o "$TMP/res.zip"

echo "[2/7] aapt2 link"
"$BT/aapt2.exe" link -o "$TMP/base.apk" -I "$AJ" \
    --manifest "$PROJ/AndroidManifest.xml" --java "$TMP/gen" "$TMP/res.zip"

echo "[3/7] javac"
"$JAVAC" -encoding UTF-8 --release 11 -cp "$AJ" -d "$TMP/classes" \
    "$TMP/gen/com/bomo/owc/R.java" "$PROJ/src/com/bomo/owc/"*.java

echo "[4/7] d8"
"$BT/d8.bat" --release --lib "$AJ" --output "$TMP/dex" "$TMP"/classes/com/bomo/owc/*.class

echo "[5/7] 打包 classes.dex"
python - "$TMP/base.apk" "$TMP/dex/classes.dex" <<'PYEOF'
import sys, zipfile
apk, dex = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk, 'a', zipfile.ZIP_DEFLATED) as z:
    z.write(dex, 'classes.dex')
print("  classes.dex ->", apk)
PYEOF

echo "[6/7] zipalign"
"$BT/zipalign.exe" -f 4 "$TMP/base.apk" "$TMP/aligned.apk"

echo "[7/7] 签名（keystore 不存在则生成）"
if [ ! -f "$KEYSTORE" ]; then
    "$KEYTOOL" -genkeypair -keystore "$KEYSTORE" -alias owc \
        -keyalg RSA -keysize 2048 -validity 10950 \
        -storepass owcbomo -keypass owcbomo \
        -dname "CN=bomo, O=OWC" >/dev/null 2>&1
fi
"$BT/apksigner.bat" sign --ks "$KEYSTORE" --ks-pass pass:owcbomo \
    --out "$PROJ/owc-app-debug.apk" "$TMP/aligned.apk"

echo ""
echo "完成: $PROJ/owc-app-debug.apk"
ls -la "$PROJ/owc-app-debug.apk"
