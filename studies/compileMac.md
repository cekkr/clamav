Ecco uno script `bash` per macOS che compila ClamAV con le firme per la distribuzione, supportando le architetture x86_64 e arm64.

**Prima di eseguire lo script:**

1.  **Installare Xcode Command Line Tools:**
    ```bash
    xcode-select --install
    ```
2.  **Installare Homebrew:** Se non lo hai già, segui le istruzioni su [https://brew.sh/it/](https://brew.sh/it/)
3.  **Installare le dipendenze richieste con Homebrew:**
    ```bash
    brew install jq openssl pcre2 json-c libxml2 zlib bzip2 pkg-config automake autoconf libtool
    ```
    * `jq` è usato per analizzare il JSON della versione di ClamAV.
    * Le altre sono librerie di compilazione per ClamAV.
    * `pkg-config`, `automake`, `autoconf`, `libtool` sono strumenti di build che potrebbero essere necessari.

**Script di compilazione (`build_clamav_macos.sh`):**

```bash
#!/bin/bash

# Script per compilare ClamAV per macOS (x86_64 e arm64) per la distribuzione.

# Esci immediatamente se un comando esce con uno stato diverso da zero.
set -e
# Tratta gli errori nelle pipeline come errori per l'intera pipeline.
set -o pipefail

# --- Configurazione ---
CLAMAV_VERSION_URL="https://www.clamav.net/versions.json"
# Puoi sovrascrivere la versione di ClamAV passandola come primo argomento allo script
# Esempio: ./build_clamav_macos.sh 1.3.0
CLAMAV_VERSION_OVERRIDE="${1:-}"

# Directory di build e output
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BUILD_DIR_BASE="clamav_build_${TIMESTAMP}"
LOG_DIR="$BUILD_DIR_BASE/logs"
SOURCES_DIR="$BUILD_DIR_BASE/sources"
DIST_DIR_ROOT="clamav_dist" # Directory principale per i file di distribuzione finali

# Prefisso di installazione previsto per ClamAV nel bundle distribuito.
# ClamAV sarà configurato per cercare i suoi file (firme, config) qui.
# Se cambi questo, aggiorna anche i percorsi nei file di configurazione di esempio.
CONFIGURE_PREFIX="/opt/clamav_bundle"

# Architetture per cui compilare
ARCHS_TO_BUILD=("x86_64" "arm64")

# Target minimo di macOS (es. 10.13, 10.15, 11.0). Impostalo in base alla compatibilità desiderata.
MACOSX_MIN_VERSION="10.15"

# Numero di job paralleli per make
NUM_JOBS=$(sysctl -n hw.ncpu)

# --- Funzioni Helper ---

# Controlla se un comando esiste
ensure_command() {
  if ! command -v "$1" &> /dev/null; then
    echo "Errore: il comando '$1' non è stato trovato. Per favore, installalo."
    exit 1
  fi
}

# Stampa un messaggio informativo
info() {
  echo "INFO: $1"
}

# Stampa un messaggio di errore e esce
error() {
  echo "ERRORE: $1" >&2
  exit 1
}

# --- Script Principale ---
main() {
  info "Avvio della compilazione di ClamAV per macOS."

  # 0. Controlli preliminari
  ensure_command "curl"
  ensure_command "jq"
  ensure_command "tar"
  ensure_command "make"
  ensure_command "lipo"
  ensure_command "brew"
  ensure_command "pkg-config"

  # 1. Ottieni la versione di ClamAV
  if [ -n "$CLAMAV_VERSION_OVERRIDE" ]; then
    CLAMAV_VERSION="$CLAMAV_VERSION_OVERRIDE"
    info "Utilizzo della versione di ClamAV specificata: $CLAMAV_VERSION"
  else
    info "Recupero dell'ultima versione stabile di ClamAV..."
    CLAMAV_VERSION=$(curl -s "$CLAMAV_VERSION_URL" | jq -r '.versions.clamav')
    if [ -z "$CLAMAV_VERSION" ] || [ "$CLAMAV_VERSION" == "null" ]; then
      error "Impossibile recuperare l'ultima versione di ClamAV. Controlla $CLAMAV_VERSION_URL"
    fi
    info "Ultima versione di ClamAV: $CLAMAV_VERSION"
  fi

  CLAMAV_SOURCE_URL="https://www.clamav.net/downloads/production/clamav-${CLAMAV_VERSION}.tar.gz"
  CLAMAV_SOURCE_TAR="clamav-${CLAMAV_VERSION}.tar.gz"
  CLAMAV_SOURCE_DIR="clamav-${CLAMAV_VERSION}"

  # 2. Crea directory di lavoro
  info "Creazione delle directory di lavoro..."
  mkdir -p "$LOG_DIR"
  mkdir -p "$SOURCES_DIR"
  mkdir -p "$DIST_DIR_ROOT" # Directory finale per la distribuzione

  ORIGINAL_PWD=$(pwd)

  # 3. Scarica ed estrai il sorgente di ClamAV
  cd "$SOURCES_DIR"
  if [ ! -f "$CLAMAV_SOURCE_TAR" ]; then
    info "Download del sorgente di ClamAV da $CLAMAV_SOURCE_URL..."
    curl -L -o "$CLAMAV_SOURCE_TAR" "$CLAMAV_SOURCE_URL"
  else
    info "Il file sorgente di ClamAV $CLAMAV_SOURCE_TAR esiste già."
  fi

  if [ -d "$CLAMAV_SOURCE_DIR" ]; then
    info "La directory sorgente $CLAMAV_SOURCE_DIR esiste già. Rimozione per una nuova estrazione."
    rm -rf "$CLAMAV_SOURCE_DIR"
  fi
  info "Estrazione del sorgente di ClamAV..."
  tar -xzf "$CLAMAV_SOURCE_TAR"
  cd "$ORIGINAL_PWD" # Torna alla directory originale per i percorsi relativi

  # Prefissi Homebrew per le dipendenze
  # Homebrew installa in /opt/homebrew su ARM e /usr/local su Intel. `brew --prefix` gestisce questo.
  OPENSSL_PREFIX=$(brew --prefix openssl@3)
  PCRE2_PREFIX=$(brew --prefix pcre2)
  JSONC_PREFIX=$(brew --prefix json-c)
  LIBXML2_PREFIX=$(brew --prefix libxml2)
  ZLIB_PREFIX=$(brew --prefix zlib)
  BZIP2_PREFIX=$(brew --prefix bzip2) # ClamAV usa pkg-config per bzip2, quindi il prefisso è per riferimento

  # 4. Compila per ogni architettura
  for ARCH in "${ARCHS_TO_BUILD[@]}"; do
    info "--- Inizio compilazione per l'architettura: $ARCH ---"
    BUILD_ARCH_DIR="$BUILD_DIR_BASE/$ARCH"
    STAGING_ARCH_DIR="$BUILD_DIR_BASE/staging/$ARCH" # Directory di staging per 'make install'

    mkdir -p "$BUILD_ARCH_DIR"
    mkdir -p "$STAGING_ARCH_DIR"
    cd "$SOURCES_DIR/$CLAMAV_SOURCE_DIR"

    # Pulisci le build precedenti
    if [ -f "Makefile" ]; then
        make distclean || info "make distclean fallito, potrebbe essere la prima build."
    fi

    # Impostazioni specifiche dell'architettura
    TARGET_HOST="${ARCH}-apple-darwin"
    export CFLAGS="-arch $ARCH -mmacosx-version-min=${MACOSX_MIN_VERSION} -O2 -I${OPENSSL_PREFIX}/include -I${PCRE2_PREFIX}/include -I${JSONC_PREFIX}/include -I${LIBXML2_PREFIX}/include -I${ZLIB_PREFIX}/include -I${BZIP2_PREFIX}/include"
    export CXXFLAGS="-arch $ARCH -mmacosx-version-min=${MACOSX_MIN_VERSION} -O2 -I${OPENSSL_PREFIX}/include -I${PCRE2_PREFIX}/include -I${JSONC_PREFIX}/include -I${LIBXML2_PREFIX}/include -I${ZLIB_PREFIX}/include -I${BZIP2_PREFIX}/include"
    export LDFLAGS="-arch $ARCH -mmacosx-version-min=${MACOSX_MIN_VERSION} -L${OPENSSL_PREFIX}/lib -L${PCRE2_PREFIX}/lib -L${JSONC_PREFIX}/lib -L${LIBXML2_PREFIX}/lib -L${ZLIB_PREFIX}/lib -L${BZIP2_PREFIX}/lib"
    
    # pkg-config path (assicura che le librerie corrette per l'architettura siano trovate se brew le separa)
    # Solitamente i flag CFLAGS/LDFLAGS sono sufficienti per le librerie universali di brew.
    export PKG_CONFIG_PATH="${OPENSSL_PREFIX}/lib/pkgconfig:${PCRE2_PREFIX}/lib/pkgconfig:${JSONC_PREFIX}/lib/pkgconfig:${LIBXML2_PREFIX}/lib/pkgconfig:${ZLIB_PREFIX}/lib/pkgconfig:${BZIP2_PREFIX}/lib/pkgconfig"

    info "Configurazione di ClamAV per $ARCH..."
    # Nota: --sysconfdir e --datadir sono relativi a --prefix
    # ClamAV installerà clamd.conf in $PREFIX/etc/clamd.conf (o $PREFIX/etc/clamav/clamd.conf)
    # e le firme in $PREFIX/share/clamav/
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
      >& "$ORIGINAL_PWD/$LOG_DIR/configure_${ARCH}.log"

    info "Compilazione di ClamAV per $ARCH... (log in $ORIGINAL_PWD/$LOG_DIR/make_${ARCH}.log)"
    make -j"$NUM_JOBS" >& "$ORIGINAL_PWD/$LOG_DIR/make_${ARCH}.log"

    info "Installazione di ClamAV per $ARCH in $STAGING_ARCH_DIR... (log in $ORIGINAL_PWD/$LOG_DIR/make_install_${ARCH}.log)"
    make install DESTDIR="$STAGING_ARCH_DIR" >& "$ORIGINAL_PWD/$LOG_DIR/make_install_${ARCH}.log"

    cd "$ORIGINAL_PWD" # Torna alla directory PWD originale
    info "--- Compilazione per $ARCH completata ---"
  done

  # 5. Crea directory di distribuzione finale e binari/librerie universali
  info "Creazione della directory di distribuzione finale: $DIST_DIR_ROOT"
  DIST_BIN="$DIST_DIR_ROOT/bin"
  DIST_LIB="$DIST_DIR_ROOT/lib"
  DIST_INCLUDE="$DIST_DIR_ROOT/include" # Includi anche gli header, se necessario
  DIST_SHARE_CLAMAV="$DIST_DIR_ROOT/share/clamav"
  DIST_ETC_CLAMAV="$DIST_DIR_ROOT/etc/clamav"
  DIST_MAN="$DIST_DIR_ROOT/share/man" # Pagine man

  mkdir -p "$DIST_BIN" "$DIST_LIB" "$DIST_INCLUDE/clamav" "$DIST_SHARE_CLAMAV" "$DIST_ETC_CLAMAV" "$DIST_MAN"

  STAGING_DIR_X86_64="$BUILD_DIR_BASE/staging/x86_64$CONFIGURE_PREFIX"
  STAGING_DIR_ARM64="$BUILD_DIR_BASE/staging/arm64$CONFIGURE_PREFIX"

  # Eseguibili da rendere universali
  BINS_TO_LIPO=("clamscan" "clamd" "freshclam" "clambc" "sigtool" "clamconf" "clamsubmit")
  info "Creazione di binari universali..."
  for bin_name in "${BINS_TO_LIPO[@]}"; do
    if [ -f "$STAGING_DIR_X86_64/bin/$bin_name" ] && [ -f "$STAGING_DIR_ARM64/bin/$bin_name" ]; then
      lipo -create "$STAGING_DIR_X86_64/bin/$bin_name" "$STAGING_DIR_ARM64/bin/$bin_name" \
           -output "$DIST_BIN/$bin_name"
      info "Creato binario universale: $DIST_BIN/$bin_name"
    else
      info "ATTENZIONE: Binario $bin_name non trovato per entrambe le architetture. Saltato."
    fi
  done

  # Librerie da rendere universali
  # I nomi delle librerie potrebbero avere versioni (es. libclamav.9.dylib)
  # Prendiamo i nomi dalla build x86_64 come riferimento
  info "Creazione di librerie universali..."
  if [ -d "$STAGING_DIR_X86_64/lib" ]; then
    # shellcheck disable=SC2044 # find è sicuro qui
    for lib_file_x86 in $(find "$STAGING_DIR_X86_64/lib" -name "libclamav*.dylib" -o -name "libfreshclam*.dylib"); do
      lib_basename=$(basename "$lib_file_x86")
      lib_file_arm64="$STAGING_DIR_ARM64/lib/$lib_basename"
      if [ -f "$lib_file_arm64" ]; then
        lipo -create "$lib_file_x86" "$lib_file_arm64" -output "$DIST_LIB/$lib_basename"
        info "Creata libreria universale: $DIST_LIB/$lib_basename"

        # Correzione rpath per le librerie (per renderle auto-contenute)
        # Le librerie dovrebbero avere un id che usa @rpath
        install_name_tool -id "@rpath/$lib_basename" "$DIST_LIB/$lib_basename"

        # Correzione riferimenti tra librerie (se necessario, es. libfreshclam linka libclamav)
        # Questo è un esempio, potrebbe essere necessario analizzare le dipendenze con otool -L
        # otool -L $DIST_LIB/$lib_basename | grep "$CONFIGURE_PREFIX" | awk '{print $1}' | while read old_path; do
        #   dep_lib_basename=$(basename "$old_path")
        #   install_name_tool -change "$old_path" "@rpath/$dep_lib_basename" "$DIST_LIB/$lib_basename"
        # done
      else
        info "ATTENZIONE: Libreria $lib_basename non trovata per arm64. Saltata."
      fi
    done
    # Copia altri file .a o .la se presenti e necessari (opzionale)
    find "$STAGING_DIR_X86_64/lib" \( -name "*.a" -o -name "*.la" \) -exec cp {} "$DIST_LIB/" \;
  fi
  
  # Correggi i percorsi delle librerie nei binari universali
  info "Correzione dei percorsi delle librerie nei binari..."
  for bin_name in "${BINS_TO_LIPO[@]}"; do
    if [ -f "$DIST_BIN/$bin_name" ]; then
        # Aggiungi rpath per cercare le librerie in ../lib rispetto al binario
        install_name_tool -add_rpath "@loader_path/../lib" "$DIST_BIN/$bin_name"
        
        # Cambia i percorsi delle librerie hardcoded per usare @rpath
        # shellcheck disable=SC2044 # find è sicuro qui
        for lib_file_x86 in $(find "$STAGING_DIR_X86_64/lib" -name "libclamav*.dylib" -o -name "libfreshclam*.dylib"); do
            lib_basename=$(basename "$lib_file_x86")
            original_lib_path="$CONFIGURE_PREFIX/lib/$lib_basename" # Percorso come sarebbe stato installato
            # A volte il percorso potrebbe includere la directory di staging se DESTDIR non è gestito perfettamente dal makefile per i link rpath
            # otool -L $STAGING_DIR_X86_64/bin/$bin_name # per ispezionare
            install_name_tool -change "$original_lib_path" "@rpath/$lib_basename" "$DIST_BIN/$bin_name" 2>/dev/null || \
            install_name_tool -change "$STAGING_DIR_X86_64/lib/$lib_basename" "@rpath/$lib_basename" "$DIST_BIN/$bin_name" 2>/dev/null || \
            info "Nessuna modifica del percorso per $lib_basename in $bin_name (potrebbe essere già corretto o non linkato)"
        done
    fi
  done


  # Copia file include (da una delle architetture, di solito sono identici)
  info "Copia dei file header..."
  cp -R "$STAGING_DIR_X86_64/include/"* "$DIST_INCLUDE/"

  # Copia pagine man (da una delle architetture)
  info "Copia delle pagine man..."
  if [ -d "$STAGING_DIR_X86_64/share/man" ]; then
    cp -R "$STAGING_DIR_X86_64/share/man/"* "$DIST_MAN/"
  fi
  # Rimuovi eventuali file .keep per evitare directory vuote se pkgconfig non crea nulla
  find "$DIST_LIB/pkgconfig" -name ".keep" -type f -delete 2>/dev/null || true
  rmdir "$DIST_LIB/pkgconfig" 2>/dev/null || true

  # 6. Scarica le firme
  info "Download delle firme di ClamAV (main, daily, bytecode)..."
  curl -L -o "$DIST_SHARE_CLAMAV/main.cvd" "https://database.clamav.net/main.cvd"
  curl -L -o "$DIST_SHARE_CLAMAV/daily.cvd" "https://database.clamav.net/daily.cvd"
  curl -L -o "$DIST_SHARE_CLAMAV/bytecode.cvd" "https://database.clamav.net/bytecode.cvd"

  # 7. Crea file di configurazione di esempio
  info "Creazione dei file di configurazione di esempio..."
  # clamd.conf.sample
  cat > "$DIST_ETC_CLAMAV/clamd.conf.sample" <<EOF
# Esempio di file di configurazione per clamd
# Commenta la riga 'Example' per abilitare questa configurazione
# Example

LogFile /tmp/clamd.log
LogTime yes
PidFile /tmp/clamd.pid
LocalSocket /tmp/clamd.socket
# TCPSocket 3310
# TCPAddr 127.0.0.1
User $(whoami) # Esegui come utente corrente (per test facili, in produzione usa un utente dedicato)

# Path alle firme. Deve corrispondere al CONFIGURE_PREFIX usato durante la compilazione.
DatabaseDirectory $CONFIGURE_PREFIX/share/clamav

# Altre opzioni utili:
# ScanRAR yes
# ScanArchives yes
# MaxScanSize 200M
# MaxFileSize 100M
# MaxRecursion 16
# MaxFiles 10000
EOF

  # freshclam.conf.sample
  cat > "$DIST_ETC_CLAMAV/freshclam.conf.sample" <<EOF
# Esempio di file di configurazione per freshclam
# Commenta la riga 'Example' per abilitare questa configurazione
# Example

# Path alle firme. Deve corrispondere al CONFIGURE_PREFIX usato durante la compilazione.
DatabaseDirectory $CONFIGURE_PREFIX/share/clamav

UpdateLogFile /tmp/freshclam.log
PidFile /tmp/freshclam.pid
DatabaseOwner $(whoami) # Permetti all'utente corrente di aggiornare, in produzione usa un utente dedicato

# Specifica uno o più mirror. database.clamav.net è un buon punto di partenza.
DatabaseMirror database.clamav.net
# DatabaseMirror db.XY.clamav.net # Sostituisci XY con il tuo codice paese
# DNSDatabaseInfo current.cvd.clamav.net

# Numero di controlli al giorno (24 volte = ogni ora)
Checks 24
# Script da eseguire dopo l'aggiornamento (opzionale)
# OnUpdateExecute /path/to/command

# NotifyClamd /path/to/clamd.conf # Se clamd è in esecuzione, notificagli di ricaricare il database
# Per usare NotifyClamd, assicurati che clamd.conf abbia 'SelfCheck' (default 1800 secondi)
# o che clamd sia configurato per ascoltare i comandi.
# Se usi LocalSocket, il percorso in clamd.conf deve essere accessibile.
# NotifyClamd $CONFIGURE_PREFIX/etc/clamd.conf
EOF

  info "--- Compilazione e packaging di ClamAV completati ---"
  info "I file di distribuzione si trovano in: $ORIGINAL_PWD/$DIST_DIR_ROOT"
  info "La directory di build è: $ORIGINAL_PWD/$BUILD_DIR_BASE"
  info "I log di compilazione si trovano in: $ORIGINAL_PWD/$LOG_DIR"
  info ""
  info "Per usare questa build:"
  info "1. Copia/sposta la directory '$DIST_DIR_ROOT' nella sua destinazione finale (es. '$CONFIGURE_PREFIX')."
  info "   Se la sposti in una posizione diversa da '$CONFIGURE_PREFIX', dovrai aggiornare"
  info "   i percorsi 'DatabaseDirectory' nei file di configurazione."
  info "2. Copia i file *.sample da '$DIST_DIR_ROOT/etc/clamav' a '$DIST_DIR_ROOT/etc/clamav', rimuovendo '.sample',"
  info "   e modificali secondo le tue necessità (es. rimuovi la riga 'Example')."
  info "   Potrebbe essere necessario creare manualmente la directory '$CONFIGURE_PREFIX/etc/clamav' se non si copia l'intera struttura."
  info "3. Assicurati che i percorsi LogFile, PidFile siano scrivibili dall'utente che esegue clamd/freshclam."
  info "4. Esegui '$DIST_DIR_ROOT/bin/freshclam' per il primo download/aggiornamento delle firme (se necessario)."
  info "5. Esegui '$DIST_DIR_ROOT/bin/clamd'."
  info "6. Esegui scansioni con '$DIST_DIR_ROOT/bin/clamscan'."
  info "NOTA: Le librerie sono state linkate usando @rpath. I binari in '$DIST_DIR_ROOT/bin' dovrebbero trovare"
  info "      le librerie in '$DIST_DIR_ROOT/lib' automaticamente, rendendo la directory '$DIST_DIR_ROOT' portabile."

}

# Esegui la funzione main
main "$@"
```

**Come usare lo script:**

1.  Salva lo script come `build_clamav_macos.sh` in una directory a tua scelta.
2.  Rendi lo script eseguibile: `chmod +x build_clamav_macos.sh`.
3.  Esegui lo script:
    * Per compilare l'ultima versione di ClamAV: `./build_clamav_macos.sh`
    * Per compilare una versione specifica (es. 1.2.1): `./build_clamav_macos.sh 1.2.1`

Lo script creerà:

* Una directory `clamav_build_YYYYMMDD_HHMMSS` contenente i sorgenti, i log e i file di staging per ogni architettura.
* Una directory `clamav_dist` contenente la distribuzione finale di ClamAV con:
    * `bin/`: Eseguibili universali (clamscan, clamd, freshclam, ecc.)
    * `lib/`: Librerie dinamiche universali (`.dylib`) e altri file di libreria.
    * `include/`: File header di ClamAV.
    * `share/clamav/`: Firme dei virus scaricate (`main.cvd`, `daily.cvd`, `bytecode.cvd`).
    * `share/man/`: Pagine di manuale.
    * `etc/clamav/`: File di configurazione di esempio (`clamd.conf.sample`, `freshclam.conf.sample`).

**Note importanti:**

* **Percorso di installazione (`CONFIGURE_PREFIX`):** Lo script imposta ClamAV per aspettarsi di essere eseguito da `/opt/clamav_bundle`. Se intendi installare la directory `clamav_dist` in una posizione diversa (ad esempio, all'interno di un `.app` bundle o in `/usr/local/`), dovrai:
    1.  Modificare la variabile `CONFIGURE_PREFIX` nello script *prima* di eseguirlo.
    2.  Assicurarti che i percorsi `DatabaseDirectory` nei file di configurazione di esempio (`clamd.conf.sample`, `freshclam.conf.sample`) corrispondano al nuovo `CONFIGURE_PREFIX`.
    La parte relativa a `rpath` cerca di rendere la directory `clamav_dist` più portabile, in modo che i binari in `bin/` trovino le librerie in `lib/` indipendentemente da dove si trovi `clamav_dist`, ma i percorsi hardcoded per le firme nei file di configurazione rimangono un punto da considerare.
* **Utente:** I file di configurazione di esempio impostano l'utente come l'utente corrente (`$(whoami)`) per `DatabaseOwner` e `User`. In un ambiente di produzione, dovresti creare un utente e un gruppo dedicati (`clamav` o simile) per eseguire `clamd` e `freshclam` per motivi di sicurezza e aggiornare di conseguenza i file di configurazione.
* **Dipendenze:** Lo script presuppone che le dipendenze di Homebrew siano installate e accessibili.
* **Firme:** Le firme vengono scaricate durante il processo di compilazione. Dovrai eseguire `freshclam` regolarmente per mantenerle aggiornate.
* **Test:** Testa accuratamente la build risultante nel tuo ambiente di destinazione.
* **`rpath` e `install_name_tool`:** Lo script tenta di impostare `@rpath` per le librerie e i binari per migliorare la portabilità della directory `clamav_dist`. Questo significa che i binari in `clamav_dist/bin` dovrebbero essere in grado di trovare le librerie in `clamav_dist/lib` senza che `DYLD_LIBRARY_PATH` sia impostato, rendendo la cartella `clamav_dist` più auto-contenuta. Questo può essere complesso e potrebbe richiedere aggiustamenti a seconda della versione specifica di ClamAV e delle configurazioni di build. Controlla con `otool -L <path_to_binary_or_library>` per verificare i percorsi delle librerie.