#!/bin/bash

# Configure:
# brew install autoconf automake libtool pkg-config
# ./autogen.sh

# Script per compilare ClamAV per macOS (x86_64 e arm64) per la distribuzione.
# PRESUPPONE DI ESSERE ESEGUITO DALLA RADICE DELLA DIRECTORY DEI SORGENTI DI CLAMAV.

# Esci immediatamente se un comando esce con uno stato diverso da zero.
set -e
# Tratta gli errori nelle pipeline come errori per l'intera pipeline.
set -o pipefail

# --- Funzioni Helper ---
info() {
  echo "INFO: $1"
}

error() {
  echo "ERRORE: $1" >&2
  exit 1
}

# Controlla se un comando esiste
ensure_command() {
  if ! command -v "$1" &> /dev/null; then
    # Nota: qui non uso la funzione error() per evitare potenziale ricorsione
    # se questa funzione viene chiamata prima che error() sia definita o se error() stessa ha problemi.
    echo "FATALE: Il comando '$1' non è stato trovato. Per favore, installalo e assicurati che sia nel tuo PATH."
    exit 1
  fi
}

# --- Configurazione ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

CLAMAV_VERSION_FROM_SOURCE=""
if [ -f "configure.ac" ]; then
    # Estrae la versione da AC_INIT([clamav], [X.Y.Z], ...) in configure.ac
    # Prende la prima riga che matcha, nel caso ci fossero commenti o altro.
    CLAMAV_VERSION_FROM_SOURCE=$(grep "AC_INIT(\[clamav\]" configure.ac | head -n1 | sed -n 's/.*AC_INIT(\[clamav\],\s*\[\([^]]*\)\].*/\1/p')
fi

if [ -z "$CLAMAV_VERSION_FROM_SOURCE" ]; then
    CLAMAV_VERSION_FROM_SOURCE="unknown_version" # Fallback
    info "ATTENZIONE: Impossibile determinare la versione di ClamAV da configure.ac. Uso '$CLAMAV_VERSION_FROM_SOURCE'."
else
    info "Rilevata versione di ClamAV dai sorgenti (presunta): $CLAMAV_VERSION_FROM_SOURCE"
fi

BUILD_DIR_BASE="clamav_build_${CLAMAV_VERSION_FROM_SOURCE}_${TIMESTAMP}"
LOG_DIR="$BUILD_DIR_BASE/logs"
DIST_DIR_ROOT="clamav_dist_${CLAMAV_VERSION_FROM_SOURCE}"

CONFIGURE_PREFIX="/opt/clamav_bundle"
ARCHS_TO_BUILD=("x86_64" "arm64")
MACOSX_MIN_VERSION="10.15"
NUM_JOBS=$(sysctl -n hw.ncpu)

# --- Script Principale ---
main() {
  info "Avvio della compilazione di ClamAV per macOS dai sorgenti locali."
  info "Versione presunta dai sorgenti: $CLAMAV_VERSION_FROM_SOURCE"

  # 0. Controlli preliminari per i comandi usati nello script
  ensure_command "make"
  ensure_command "lipo"
  ensure_command "brew"
  ensure_command "pkg-config"
  ensure_command "sysctl"
  ensure_command "grep"
  ensure_command "sed"
  ensure_command "head"
  ensure_command "date"
  ensure_command "mkdir"
  ensure_command "rm" # Usato implicitamente da make distclean
  ensure_command "cat" # Usato per i file di config
  ensure_command "find" # Usato per lipo libs e copia .a/.la
  ensure_command "basename" # Usato per lipo libs
  ensure_command "install_name_tool" # Usato per rpath

  ORIGINAL_PWD=$(pwd)
  info "Creazione delle directory di lavoro (log e output)..."
  mkdir -p "$ORIGINAL_PWD/$LOG_DIR" # Log dir relativa a ORIGINAL_PWD
  mkdir -p "$ORIGINAL_PWD/$DIST_DIR_ROOT" # Dist dir relativa a ORIGINAL_PWD

  if [ ! -d "libclamav" ]; then # Controllo più specifico # [ ! -f "configure.ac" ] || 
    error "Lo script sembra non essere eseguito dalla radice dei sorgenti di ClamAV (manca 'configure.ac' o 'libclamav/'). Spostati nella directory corretta ed esegui di nuovo."
  fi

  # Prefissi Homebrew per le dipendenze
  OPENSSL_PREFIX=$(brew --prefix openssl@3)
  PCRE2_PREFIX=$(brew --prefix pcre2)
  JSONC_PREFIX=$(brew --prefix json-c)
  LIBXML2_PREFIX=$(brew --prefix libxml2)
  ZLIB_PREFIX=$(brew --prefix zlib)
  BZIP2_PREFIX=$(brew --prefix bzip2)

  for ARCH in "${ARCHS_TO_BUILD[@]}"; do
    info "--- Inizio compilazione per l'architettura: $ARCH ---"
    
    # Le directory di build e staging ora sono create all'interno di BUILD_DIR_BASE,
    # che è relativa a ORIGINAL_PWD.
    # Non creiamo più BUILD_ARCH_DIR separata, la build avviene in-tree dopo 'make distclean'.
    STAGING_ARCH_DIR="$ORIGINAL_PWD/$BUILD_DIR_BASE/staging/$ARCH"
    mkdir -p "$STAGING_ARCH_DIR"

    # Assicurati di essere nella directory dei sorgenti (ORIGINAL_PWD)
    cd "$ORIGINAL_PWD"

    if [ -f "Makefile" ]; then
        info "Esecuzione di 'make distclean' per pulire la build precedente per $ARCH..."
        make distclean > "$ORIGINAL_PWD/$LOG_DIR/distclean_${ARCH}.log" 2>&1 || info "make distclean fallito o non necessario per $ARCH."
    fi
    
    # Se hai autogen.sh e vuoi rigenerare i file di build
    # if [ "$ARCH" == "${ARCHS_TO_BUILD[0]}" ] && [ -f "autogen.sh" ]; then # Esegui solo una volta
    #    info "Esecuzione di autogen.sh..."
    #    ./autogen.sh > "$ORIGINAL_PWD/$LOG_DIR/autogen.log" 2>&1
    # fi

    TARGET_HOST="${ARCH}-apple-darwin"
    export CFLAGS="-arch $ARCH -mmacosx-version-min=${MACOSX_MIN_VERSION} -O2 -I${OPENSSL_PREFIX}/include -I${PCRE2_PREFIX}/include -I${JSONC_PREFIX}/include -I${LIBXML2_PREFIX}/include -I${ZLIB_PREFIX}/include -I${BZIP2_PREFIX}/include"
    export CXXFLAGS="-arch $ARCH -mmacosx-version-min=${MACOSX_MIN_VERSION} -O2 -I${OPENSSL_PREFIX}/include -I${PCRE2_PREFIX}/include -I${JSONC_PREFIX}/include -I${LIBXML2_PREFIX}/include -I${ZLIB_PREFIX}/include -I${BZIP2_PREFIX}/include"
    export LDFLAGS="-arch $ARCH -mmacosx-version-min=${MACOSX_MIN_VERSION} -L${OPENSSL_PREFIX}/lib -L${PCRE2_PREFIX}/lib -L${JSONC_PREFIX}/lib -L${LIBXML2_PREFIX}/lib -L${ZLIB_PREFIX}/lib -L${BZIP2_PREFIX}/lib"
    export PKG_CONFIG_PATH="${OPENSSL_PREFIX}/lib/pkgconfig:${PCRE2_PREFIX}/lib/pkgconfig:${JSONC_PREFIX}/lib/pkgconfig:${LIBXML2_PREFIX}/lib/pkgconfig:${ZLIB_PREFIX}/lib/pkgconfig:${BZIP2_PREFIX}/lib/pkgconfig"

    info "Configurazione di ClamAV per $ARCH... (log in $LOG_DIR/configure_${ARCH}.log)"
    ./configure \
      --host="$TARGET_HOST" \
      --prefix="$CONFIGURE_PREFIX" \
      --sysconfdir="$CONFIGURE_PREFIX/etc" \
      --datadir="$CONFIGURE_PREFIX/share" \
      --disable-silent-rules \
      --disable-dependency-tracking \
      --disable-llvm \
      --disable-clamsubmit \
      --disable-milter \
      --enable-bytecode-unsigned \
      --with-openssl="$OPENSSL_PREFIX" \
      --with-pcre2="$PCRE2_PREFIX" \
      --with-libxml2="$LIBXML2_PREFIX" \
      --with-json-c="$JSONC_PREFIX" \
      --with-zlib="$ZLIB_PREFIX" \
      --with-bzip2="$BZIP2_PREFIX" \
      CFLAGS="$CFLAGS" \
      CXXFLAGS="$CXXFLAGS" \
      LDFLAGS="$LDFLAGS" \
      > "$ORIGINAL_PWD/$LOG_DIR/configure_${ARCH}.log" 2>&1

    info "Compilazione di ClamAV per $ARCH... (log in $LOG_DIR/make_${ARCH}.log)"
    make -j"$NUM_JOBS" > "$ORIGINAL_PWD/$LOG_DIR/make_${ARCH}.log" 2>&1

    info "Installazione di ClamAV per $ARCH in $STAGING_ARCH_DIR... (log in $LOG_DIR/make_install_${ARCH}.log)"
    make install DESTDIR="$STAGING_ARCH_DIR" > "$ORIGINAL_PWD/$LOG_DIR/make_install_${ARCH}.log" 2>&1
    
    info "--- Compilazione per $ARCH completata ---"
  done

  info "Creazione della directory di distribuzione finale: $ORIGINAL_PWD/$DIST_DIR_ROOT"
  DIST_BIN="$ORIGINAL_PWD/$DIST_DIR_ROOT/bin"
  DIST_LIB="$ORIGINAL_PWD/$DIST_DIR_ROOT/lib"
  DIST_INCLUDE="$ORIGINAL_PWD/$DIST_DIR_ROOT/include"
  DIST_SHARE_CLAMAV="$ORIGINAL_PWD/$DIST_DIR_ROOT/share/clamav"
  DIST_ETC_CLAMAV="$ORIGINAL_PWD/$DIST_DIR_ROOT/etc/clamav"
  DIST_MAN="$ORIGINAL_PWD/$DIST_DIR_ROOT/share/man"

  mkdir -p "$DIST_BIN" "$DIST_LIB" "$DIST_INCLUDE/clamav" "$DIST_SHARE_CLAMAV" "$DIST_ETC_CLAMAV" "$DIST_MAN/man1" "$DIST_MAN/man5" "$DIST_MAN/man8"


  STAGING_CONTENT_X86_64="$ORIGINAL_PWD/$BUILD_DIR_BASE/staging/x86_64$CONFIGURE_PREFIX"
  STAGING_CONTENT_ARM64="$ORIGINAL_PWD/$BUILD_DIR_BASE/staging/arm64$CONFIGURE_PREFIX"

  BINS_TO_LIPO=("clamscan" "clamd" "freshclam" "clambc" "sigtool" "clamconf" "clamsubmit")
  info "Creazione di binari universali..."
  for bin_name in "${BINS_TO_LIPO[@]}"; do
    input_x86_64="$STAGING_CONTENT_X86_64/bin/$bin_name"
    input_arm64="$STAGING_CONTENT_ARM64/bin/$bin_name"
    output_universal="$DIST_BIN/$bin_name"
    
    if [ -f "$input_x86_64" ] && [ -f "$input_arm64" ]; then
      lipo -create "$input_x86_64" "$input_arm64" -output "$output_universal"
      info "Creato binario universale: $output_universal"
      
      install_name_tool -add_rpath "@loader_path/../lib" "$output_universal"
      # shellcheck disable=SC2044 # find è usato in un contesto sicuro qui
      for lib_file_ref in $(find "$STAGING_CONTENT_X86_64/lib" -name "libclamav*.dylib" -o -name "libfreshclam*.dylib"); do
          lib_basename=$(basename "$lib_file_ref")
          original_lib_path_in_bin="$CONFIGURE_PREFIX/lib/$lib_basename" # Come il binario si aspetta di trovarla
          
          # Prova a cambiare il percorso della libreria nel binario. Potrebbe non esserci se staticamente linkato o non usato.
          install_name_tool -change "$original_lib_path_in_bin" "@rpath/$lib_basename" "$output_universal" 2>/dev/null || \
          info "Nessuna modifica del percorso per $lib_basename in $output_universal (potrebbe essere già corretto o non linkato)"
      done
    else
      missing_paths=""
      [ ! -f "$input_x86_64" ] && missing_paths+=" $input_x86_64 (x86_64)"
      [ ! -f "$input_arm64" ] && missing_paths+=" $input_arm64 (arm64)"
      info "ATTENZIONE: Binario $bin_name non trovato per una o entrambe le architetture. File mancanti:$missing_paths. Saltato."
    fi
  done
  
  info "Creazione di librerie universali..."
  if [ -d "$STAGING_CONTENT_X86_64/lib" ]; then
    # shellcheck disable=SC2044
    for lib_file_x86 in $(find "$STAGING_CONTENT_X86_64/lib" -name "libclamav*.dylib" -o -name "libfreshclam*.dylib"); do
      lib_basename=$(basename "$lib_file_x86")
      lib_file_arm64="$STAGING_CONTENT_ARM64/lib/$lib_basename"
      output_universal_lib="$DIST_LIB/$lib_basename"
      
      if [ -f "$lib_file_x86" ] && [ -f "$lib_file_arm64" ]; then
        lipo -create "$lib_file_x86" "$lib_file_arm64" -output "$output_universal_lib"
        info "Creata libreria universale: $output_universal_lib"
        install_name_tool -id "@rpath/$lib_basename" "$output_universal_lib"
      else
        missing_lib_paths=""
        [ ! -f "$lib_file_x86" ] && missing_lib_paths+=" $lib_file_x86 (x86_64)"
        [ ! -f "$lib_file_arm64" ] && missing_lib_paths+=" $lib_file_arm64 (arm64)"
        info "ATTENZIONE: Libreria $lib_basename non trovata per una o entrambe le architetture. File mancanti:$missing_lib_paths. Saltata."
      fi
    done
    # Copia altri file .a o .la (se presenti e se servono)
    find "$STAGING_CONTENT_X86_64/lib" \( -name "*.a" -o -name "*.la" \) -exec cp -n {} "$DIST_LIB/" \; 2>/dev/null || true
    # Copia file pkgconfig (se presenti)
    if [ -d "$STAGING_CONTENT_X86_64/lib/pkgconfig" ]; then
        mkdir -p "$DIST_LIB/pkgconfig"
        cp -n "$STAGING_CONTENT_X86_64/lib/pkgconfig/"*.pc "$DIST_LIB/pkgconfig/" 2>/dev/null || true
    fi
  fi

  info "Copia dei file header..."
  if [ -d "$STAGING_CONTENT_X86_64/include/clamav" ]; then # Più specifico
    cp -R "$STAGING_CONTENT_X86_64/include/clamav/"* "$DIST_INCLUDE/clamav/"
  else
    info "ATTENZIONE: Directory include/clamav non trovata in $STAGING_CONTENT_X86_64/include. Header non copiati."
  fi

  info "Copia delle pagine man..."
  # Copia le pagine man, cercando nelle sottodirectory comuni man1, man5, man8
  for mandir_short in man1 man5 man8; do
    source_mandir="$STAGING_CONTENT_X86_64/share/man/$mandir_short"
    dest_mandir="$DIST_MAN/$mandir_short"
    if [ -d "$source_mandir" ]; then
      mkdir -p "$dest_mandir"
      # shellcheck disable=SC2086 # L'espansione qui è intenzionale
      cp -n $source_mandir/* $dest_mandir/ 2>/dev/null || true
    fi
  done


  info "Download delle firme di ClamAV (main, daily, bytecode)..."
  ensure_command "curl" # Ora curl serve solo per questo
  curl -L --connect-timeout 15 --retry 3 -o "$DIST_SHARE_CLAMAV/main.cvd" "https://database.clamav.net/main.cvd"
  curl -L --connect-timeout 15 --retry 3 -o "$DIST_SHARE_CLAMAV/daily.cvd" "https://database.clamav.net/daily.cvd"
  curl -L --connect-timeout 15 --retry 3 -o "$DIST_SHARE_CLAMAV/bytecode.cvd" "https://database.clamav.net/bytecode.cvd"

  info "Creazione dei file di configurazione di esempio..."
  cat > "$DIST_ETC_CLAMAV/clamd.conf.sample" <<EOF
# Esempio di file di configurazione per clamd
# Commenta la riga 'Example' per abilitare questa configurazione
# Example

LogFile /tmp/clamd.log # Modifica se necessario, es. $CONFIGURE_PREFIX/var/log/clamd.log
LogTime yes
PidFile /tmp/clamd.pid # Modifica se necessario, es. $CONFIGURE_PREFIX/var/run/clamd.pid
LocalSocket /tmp/clamd.socket # Modifica se necessario, es. $CONFIGURE_PREFIX/var/run/clamd.socket
# TCPSocket 3310
# TCPAddr 127.0.0.1
# User clamav # Raccomandato in produzione. Crea utente 'clamav'.

DatabaseDirectory $CONFIGURE_PREFIX/share/clamav

# Per la produzione, crea directory scrivibili dall'utente 'clamav':
# $CONFIGURE_PREFIX/var/log
# $CONFIGURE_PREFIX/var/run
# $CONFIGURE_PREFIX/share/clamav (per freshclam)
EOF

  cat > "$DIST_ETC_CLAMAV/freshclam.conf.sample" <<EOF
# Esempio di file di configurazione per freshclam
# Commenta la riga 'Example' per abilitare questa configurazione
# Example

DatabaseDirectory $CONFIGURE_PREFIX/share/clamav
UpdateLogFile /tmp/freshclam.log # Modifica se necessario, es. $CONFIGURE_PREFIX/var/log/freshclam.log
PidFile /tmp/freshclam.pid # Modifica se necessario, es. $CONFIGURE_PREFIX/var/run/freshclam.pid
# DatabaseOwner clamav # Raccomandato in produzione. Permetti all'utente 'clamav' di scrivere qui.

DatabaseMirror database.clamav.net
Checks 12 # Default ClamAV è 12 controlli al giorno (ogni 2 ore)
# NotifyClamd $CONFIGURE_PREFIX/etc/clamd.conf # Assicurati che clamd.conf esista e sia leggibile
EOF

  info "--- Compilazione e packaging di ClamAV completati ---"
  info "I file di distribuzione si trovano in: $ORIGINAL_PWD/$DIST_DIR_ROOT"
  info "La directory di build (contenente staging e log) è: $ORIGINAL_PWD/$BUILD_DIR_BASE"
  info ""
  info "Per usare questa build:"
  info "1. Copia/sposta la directory '$ORIGINAL_PWD/$DIST_DIR_ROOT' nella sua destinazione finale (es. '$CONFIGURE_PREFIX')."
  info "   Se sposti in una posizione diversa da '$CONFIGURE_PREFIX', dovrai aggiornare"
  info "   i percorsi 'DatabaseDirectory' nei file di configurazione e potenzialmente i percorsi per LogFile/PidFile."
  info "2. Copia i file *.sample da '$DIST_DIR_ROOT/etc/clamav' in '$CONFIGURE_PREFIX/etc/clamav' (o dove hai messo la conf),"
  info "   rimuovendo '.sample', e modificali."
  info "3. In produzione, crea un utente 'clamav' e assicurati che abbia i permessi per le directory dei log, pid e database."
  info "4. Esegui '$DIST_BIN/freshclam' (potrebbe richiedere sudo se l'utente non ha i permessi per DatabaseDirectory)."
  info "5. Esegui '$DIST_BIN/clamd'."
}

# Esegui la funzione main
main "$@"