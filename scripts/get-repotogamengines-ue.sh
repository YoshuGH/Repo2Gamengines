#!/usr/bin/env bash
# get-repotogamengines-ue.sh
# Script interactivo para inicializar un repositorio Git + Git LFS para Unreal Engine 5
# Compatible con Git Bash en Windows

set -euo pipefail

# ── Colores ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Utilidades ──
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
header()  { echo -e "\n${BOLD}═══ $1 ═══${NC}\n"; }

ask_yn() {
    local prompt="$1" default="${2:-s}"
    local hint
    if [[ "$default" == "s" ]]; then
        hint="S [si] / n [no]"
    else
        hint="s [si] / N [no]"
    fi
    while true; do
        read -rp "$(echo -e "${CYAN}?${NC}") $prompt ($hint): " ans
        ans="${ans:-$default}"
        case "${ans,,}" in
            s|si) return 0 ;;
            n|no) return 1 ;;
            *) warn "Respuesta no valida. Usa 's' o 'n'." ;;
        esac
    done
}

ask_input() {
    local prompt="$1" default="${2:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" [${default}]"
    read -rp "$(echo -e "${CYAN}?${NC}") ${prompt}${display_default}: " ans
    echo "${ans:-$default}"
}

ask_choice() {
    # Uso: ask_choice <default_1based> "prompt" "opcion1" "opcion2" ...
    local default_idx="$1"
    local prompt="$2"
    shift 2
    local options=("$@")
    echo -e "${CYAN}?${NC} $prompt"
    for i in "${!options[@]}"; do
        local num=$((i+1))
        if [[ $num -eq $default_idx ]]; then
            echo -e "  ${BOLD}${num})${NC} ${options[$i]} ${CYAN}(default)${NC}"
        else
            echo -e "  ${BOLD}${num})${NC} ${options[$i]}"
        fi
    done
    while true; do
        read -rp "$(echo -e "${CYAN}?${NC}") Selecciona (1-${#options[@]}) [${default_idx}]: " ans
        ans="${ans:-$default_idx}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#options[@]} )); then
            return $((ans - 1))
        fi
        warn "Opcion no valida."
    done
}

# ── Variables globales ──
ENGINE_TYPE=""          # "epic" o "custom"
ENGINE_CUSTOM_MODE=""   # "local" o "remote"
ENGINE_BINARY=""        # Ruta a UnrealEditor.exe (o vacio)
ENGINE_COPY_TO_REPO=false
ENGINE_SUBMODULE_URL=""
SCRIPT_DIR=""
REPO_NAME=""
UE_PROJECT_NAME=""
GIT_USER_LOCAL=false
GIT_USER_NAME=""
GIT_USER_EMAIL=""
REMOTE_URL=""
DETECTED_ENGINES=()

# ══════════════════════════════════════════════════════════════
# Autodeteccion de requisitos
# ══════════════════════════════════════════════════════════════
phase1_prerequisites() {
    header "Autodeteccion de requisitos"

    local all_ok=true

    # Git
    if command -v git &>/dev/null; then
        local git_ver
        git_ver=$(git --version 2>/dev/null | awk '{print $3}')
        ok "Git instalado (v${git_ver})"
    else
        error "Git NO encontrado"
        all_ok=false
    fi

    # Git LFS
    if command -v git-lfs &>/dev/null || git lfs version &>/dev/null 2>&1; then
        local lfs_ver
        lfs_ver=$(git lfs version 2>/dev/null | awk '{print $1}' | sed 's/git-lfs\///')
        ok "Git LFS instalado (${lfs_ver})"
    else
        error "Git LFS NO encontrado"
        all_ok=false
    fi

    # Detectar engines de Epic Games
    info "Buscando instalaciones de Unreal Engine..."
    DETECTED_ENGINES=()

    # Buscar en Program Files
    local epic_base="/c/Program Files/Epic Games"
    if [[ -d "$epic_base" ]]; then
        while IFS= read -r -d '' engine_dir; do
            local ver_name
            ver_name=$(basename "$engine_dir")
            local binary="${engine_dir}/Engine/Binaries/Win64/UnrealEditor.exe"
            if [[ -f "$binary" ]]; then
                DETECTED_ENGINES+=("${ver_name}|${binary}")
                ok "Encontrado: ${ver_name} -> $(basename "$binary")"
            fi
        done < <(find "$epic_base" -maxdepth 1 -type d -name "UE_*" -print0 2>/dev/null)
    fi

    # Buscar via LauncherInstalled.dat
    local launcher_dat="$LOCALAPPDATA/EpicGamesLauncher/Saved/Config/Windows/LauncherInstalled.dat"
    if [[ -f "$launcher_dat" ]]; then
        while IFS= read -r line; do
            local inst_path
            inst_path=$(echo "$line" | sed 's/.*"InstallLocation"[[:space:]]*:[[:space:]]*"//' | sed 's/".*//' | sed 's/\\\\/\//g' | sed 's/\\/\//g')
            if [[ -d "$inst_path" ]]; then
                local binary="${inst_path}/Engine/Binaries/Win64/UnrealEditor.exe"
                local ver_name
                ver_name=$(basename "$inst_path")
                if [[ -f "$binary" ]]; then
                    local already_found=false
                    for existing in "${DETECTED_ENGINES[@]:-}"; do
                        [[ "$existing" == "${ver_name}|"* ]] && already_found=true && break
                    done
                    if ! $already_found; then
                        DETECTED_ENGINES+=("${ver_name}|${binary}")
                        ok "Encontrado: ${ver_name} (via Launcher)"
                    fi
                fi
            fi
        done < <(grep -i "InstallLocation" "$launcher_dat" 2>/dev/null || true)
    fi

    if [[ ${#DETECTED_ENGINES[@]} -eq 0 ]]; then
        warn "No se detectaron instalaciones de Unreal Engine de Epic Games"
    else
        ok "${#DETECTED_ENGINES[@]} instalacion(es) de UE detectada(s)"
    fi

    echo ""
    if ! $all_ok; then
        error "Faltan requisitos obligatorios (Git/Git LFS). Instalalos antes de continuar."
        exit 1
    fi

    ok "Todos los requisitos obligatorios cumplidos"
}

# ══════════════════════════════════════════════════════════════
# Configuracion del Engine
# ══════════════════════════════════════════════════════════════
phase2_engine() {
    header "Configuracion del Engine"

    ask_choice 1 "Tipo de Engine:" "Engine de Epic Games" "Engine Custom"
    local choice=$?

    if [[ $choice -eq 0 ]]; then
        ENGINE_TYPE="epic"
        if [[ ${#DETECTED_ENGINES[@]} -eq 0 ]]; then
            warn "No se detectaron engines de Epic automaticamente."
            local manual_path
            manual_path=$(ask_input "Ruta al directorio del Engine de Epic Games (ej: C:/Program Files/Epic Games/UE_5.4)")
            if [[ -n "$manual_path" ]]; then
                local binary="${manual_path}/Engine/Binaries/Win64/UnrealEditor.exe"
                if [[ -f "$binary" ]]; then
                    ENGINE_BINARY="$binary"
                    ok "UnrealEditor.exe encontrado"
                else
                    local found
                    found=$(find "$manual_path" -name "UnrealEditor.exe" -print -quit 2>/dev/null || true)
                    if [[ -n "$found" ]]; then
                        ENGINE_BINARY="$found"
                        ok "UnrealEditor.exe encontrado en: $found"
                    else
                        warn "No se encontro UnrealEditor.exe. Se usaran instrucciones manuales."
                    fi
                fi
            else
                warn "No se proporciono ruta. Se usaran instrucciones manuales."
            fi
        elif [[ ${#DETECTED_ENGINES[@]} -eq 1 ]]; then
            local ver="${DETECTED_ENGINES[0]%%|*}"
            ENGINE_BINARY="${DETECTED_ENGINES[0]#*|}"
            info "Unica version detectada: ${ver}"
            if ask_yn "Usar ${ver}?"; then
                ok "Engine seleccionado: ${ver}"
            else
                ENGINE_BINARY=""
                warn "Se usaran instrucciones manuales."
            fi
        else
            local ver_names=()
            for entry in "${DETECTED_ENGINES[@]}"; do
                ver_names+=("${entry%%|*}")
            done
            ask_choice 1 "Selecciona la version de Unreal Engine:" "${ver_names[@]}"
            local idx=$?
            ENGINE_BINARY="${DETECTED_ENGINES[$idx]#*|}"
            ok "Engine seleccionado: ${ver_names[$idx]}"
        fi
    else
        ENGINE_TYPE="custom"
        ask_choice 1 "Ubicacion del Engine Custom:" "Local (en este equipo)" "Remoto (repositorio Git)"
        local loc_choice=$?

        if [[ $loc_choice -eq 0 ]]; then
            ENGINE_CUSTOM_MODE="local"
            local engine_path
            engine_path=$(ask_input "Ruta al directorio del Engine Custom")
            # Buscar UnrealEditor.exe
            local binary="${engine_path}/Engine/Binaries/Win64/UnrealEditor.exe"
            if [[ -f "$binary" ]]; then
                ENGINE_BINARY="$binary"
                ok "UnrealEditor.exe encontrado"
            else
                # Buscar recursivamente
                local found
                found=$(find "$engine_path" -name "UnrealEditor.exe" -print -quit 2>/dev/null || true)
                if [[ -n "$found" ]]; then
                    ENGINE_BINARY="$found"
                    ok "UnrealEditor.exe encontrado en: $found"
                else
                    warn "No se encontro UnrealEditor.exe. Se usaran instrucciones manuales."
                fi
            fi

            if ask_yn "Copiar el engine al repositorio (Engine/)?"; then
                ENGINE_COPY_TO_REPO=true
            fi
        else
            ENGINE_CUSTOM_MODE="remote"
            ENGINE_SUBMODULE_URL=$(ask_input "URL del repositorio del Engine Custom")
        fi
    fi
}

# ══════════════════════════════════════════════════════════════
# Parametros del proyecto
# ══════════════════════════════════════════════════════════════
phase3_params() {
    header "Parametros del proyecto"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    info "Directorio de trabajo: ${SCRIPT_DIR}"
    REPO_NAME=$(basename "$SCRIPT_DIR")
    REPO_NAME=$(ask_input "Nombre del repositorio" "$REPO_NAME")

    local global_name global_email
    global_name=$(git config --global user.name 2>/dev/null || echo "")
    global_email=$(git config --global user.email 2>/dev/null || echo "")

    local opt_global="Global"
    if [[ -n "$global_name" || -n "$global_email" ]]; then
        opt_global="Global (name: ${global_name:-sin configurar}, email: ${global_email:-sin configurar})"
    fi

    ask_choice 1 "Configurar Usuario de Git (solo para este repo):" "$opt_global" "Especificar uno"
    local git_choice=$?

    if [[ $git_choice -eq 1 ]]; then
        GIT_USER_LOCAL=true
        GIT_USER_NAME=$(ask_input "Nombre de usuario Git")
        GIT_USER_EMAIL=$(ask_input "Email de usuario Git")
    fi

    if ask_yn "Configurar repositorio remoto?" "n"; then
        REMOTE_URL=$(ask_input "URL del repositorio remoto")
    fi
}

# ══════════════════════════════════════════════════════════════
# Confirmacion y ejecucion
# ══════════════════════════════════════════════════════════════
phase4_execute() {
    header "Resumen de configuracion"

    echo -e "  ${BOLD}Repositorio:${NC}     ${SCRIPT_DIR}"
    echo -e "  ${BOLD}Tipo Engine:${NC}     ${ENGINE_TYPE}"
    if [[ -n "$ENGINE_BINARY" ]]; then
        echo -e "  ${BOLD}Engine Binary:${NC}   ${ENGINE_BINARY}"
    fi
    if [[ "$ENGINE_TYPE" == "custom" ]]; then
        echo -e "  ${BOLD}Engine Mode:${NC}    ${ENGINE_CUSTOM_MODE}"
        if [[ "$ENGINE_CUSTOM_MODE" == "remote" ]]; then
            echo -e "  ${BOLD}Submodule URL:${NC}  ${ENGINE_SUBMODULE_URL}"
        fi
        if $ENGINE_COPY_TO_REPO; then
            echo -e "  ${BOLD}Copiar Engine:${NC}  Si"
        fi
    fi
    if $GIT_USER_LOCAL; then
        echo -e "  ${BOLD}Git User:${NC}       ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
    fi
    if [[ -n "$REMOTE_URL" ]]; then
        echo -e "  ${BOLD}Remoto:${NC}         ${REMOTE_URL}"
    fi
    echo ""

    if ! ask_yn "Continuar con esta configuracion?"; then
        error "Cancelado por el usuario."
        exit 0
    fi

    header "Creando repositorio..."

    local root="${SCRIPT_DIR}"
    cd "$root"
    info "Directorio de trabajo: $root"

    # Git init
    git init
    ok "Repositorio Git inicializado"

    # Git LFS
    git lfs install
    ok "Git LFS configurado"

    # Git user local
    if $GIT_USER_LOCAL; then
        git config user.name "$GIT_USER_NAME"
        git config user.email "$GIT_USER_EMAIL"
        ok "Usuario Git local configurado"
    fi

    # Estructura de carpetas
    info "Creando estructura de carpetas..."
    mkdir -p "DCC/Blender/characters"
    mkdir -p "DCC/3dsMax/environments"
    mkdir -p "DCC/Substance/materials"
    mkdir -p "DCC/Screenshots"
    mkdir -p "Exports/Characters"
    mkdir -p "Exports/Environments"
    mkdir -p "Exports/Materials"
    mkdir -p "Exports/Animations"

    # Engine custom
    if [[ "$ENGINE_TYPE" == "custom" ]]; then
        if [[ "$ENGINE_CUSTOM_MODE" == "remote" ]]; then
            info "Agregando engine como submodule..."
            git submodule add "$ENGINE_SUBMODULE_URL" Engine/
            git submodule update --init
            ok "Submodule agregado"
            # Buscar binario en submodule
            local sub_binary="Engine/Engine/Binaries/Win64/UnrealEditor.exe"
            if [[ -f "$sub_binary" ]]; then
                ENGINE_BINARY="$(pwd)/$sub_binary"
                ok "UnrealEditor.exe encontrado en submodule"
            else
                local found
                found=$(find Engine/ -name "UnrealEditor.exe" -print -quit 2>/dev/null || true)
                if [[ -n "$found" ]]; then
                    ENGINE_BINARY="$(pwd)/$found"
                    ok "UnrealEditor.exe encontrado: $found"
                else
                    warn "No se encontro UnrealEditor.exe precompilado en el submodule."
                    ENGINE_BINARY=""
                fi
            fi
        elif [[ "$ENGINE_CUSTOM_MODE" == "local" ]] && $ENGINE_COPY_TO_REPO; then
            info "Copiando engine al repositorio (esto puede tomar tiempo)..."
            local src_dir
            src_dir=$(dirname "$(dirname "$(dirname "$(dirname "$ENGINE_BINARY")")")")
            cp -r "$src_dir" Engine/
            ok "Engine copiado a Engine/"
        else
            mkdir -p Engine
        fi
    fi

    # .gitignore raiz
    info "Creando .gitignore (raiz)..."
    cat > .gitignore << 'GITIGNORE_ROOT'
# Carpetas de VS y herramientas de desarrollo
.vs/
.vscode/
.idea/

# Unreal Engine personalizado (descomentar solo si requieres un Engine personalizado compilado)
# Engine/Build/
# Engine/Intermediate/
# Engine/Binaries/

# Archivos de trabajo en progreso en DCC (opcional, solo si prefieres no versionar borradores)
# DCC/working/
# DCC/temp/

# Ignorar los backups automaticos
DCC/*.blend[1-99]
GITIGNORE_ROOT
    ok ".gitignore (raiz) creado"

    # .gitattributes
    info "Creando .gitattributes..."
    cat > .gitattributes << 'GITATTRIBUTES'
# Auto detectar archivos de texto y normalizar finales de linea
* text=auto

# Archivos de Unreal Engine - Siempre manejados por Git LFS
*.uasset filter=lfs diff=lfs merge=lfs -text
*.umap filter=lfs diff=lfs merge=lfs -text

# Formatos de importacion 3D - Manejados por Git LFS
*.fbx filter=lfs diff=lfs merge=lfs -text
*.obj filter=lfs diff=lfs merge=lfs -text
*.3ds filter=lfs diff=lfs merge=lfs -text
*.gltf filter=lfs diff=lfs merge=lfs -text
*.glb filter=lfs diff=lfs merge=lfs -text

# Texturas e imagenes - Manejados por Git LFS
*.png filter=lfs diff=lfs merge=lfs -text
*.jpg filter=lfs diff=lfs merge=lfs -text
*.jpeg filter=lfs diff=lfs merge=lfs -text
*.tga filter=lfs diff=lfs merge=lfs -text
*.exr filter=lfs diff=lfs merge=lfs -text
*.tiff filter=lfs diff=lfs merge=lfs -text

# Audio - Manejado por Git LFS
*.wav filter=lfs diff=lfs merge=lfs -text
*.mp3 filter=lfs diff=lfs merge=lfs -text
*.flac filter=lfs diff=lfs merge=lfs -text

# Archivos de DCC - Manejados por Git LFS
*.blend filter=lfs diff=lfs merge=lfs -text
*.max filter=lfs diff=lfs merge=lfs -text
*.psd filter=lfs diff=lfs merge=lfs -text
*.xcf filter=lfs diff=lfs merge=lfs -text
*.spp filter=lfs diff=lfs merge=lfs -text

# Videos - Manejados por Git LFS (opcional, segun necesites)
*.mp4 filter=lfs diff=lfs merge=lfs -text
*.mov filter=lfs diff=lfs merge=lfs -text
*.avi filter=lfs diff=lfs merge=lfs -text

# Archivos de codigo y configuracion - Git tradicional (no LFS)
*.cpp text
*.h text
*.cs text
*.json text
*.xml text
*.ini text
*.txt text
GITATTRIBUTES
    ok ".gitattributes creado"

    # README.md
    info "Creando README.md..."
    cat > README.md << README_EOF
# ${REPO_NAME}

Proyecto de Unreal Engine 5 con Git + Git LFS.

## Estructura
- **DCC/** - Archivos de trabajo de artistas (Blender, 3ds Max, Substance)
- **Exports/** - Exportaciones finales listas para importar en UE
README_EOF
    if [[ "$ENGINE_TYPE" == "custom" ]]; then
        echo "- **Engine/** - Engine personalizado" >> README.md
    fi
    ok "README.md creado"

    # Archivos .gitkeep para carpetas vacias
    for dir in DCC/Blender/characters DCC/3dsMax/environments DCC/Substance/materials DCC/Screenshots Exports/Characters Exports/Environments Exports/Materials Exports/Animations; do
        touch "$dir/.gitkeep"
    done

    # Commit inicial
    info "Creando commit inicial..."
    git add .gitignore .gitattributes README.md
    git add DCC/ Exports/
    if [[ -f .gitmodules ]]; then
        git add .gitmodules Engine/
    fi
    git commit -m "Initial: Configure Git and Git LFS for Unreal Engine project"
    ok "Commit inicial creado"

    # Push del commit inicial si hay remoto
    if [[ -n "$REMOTE_URL" ]]; then
        info "Configurando repositorio remoto..."
        git remote add origin "$REMOTE_URL"
        git branch -M main
        git push -u origin main
        ok "Push del commit inicial al remoto completado"
    fi
}

# ══════════════════════════════════════════════════════════════
# Crear proyecto UE
# ══════════════════════════════════════════════════════════════
phase5_ue_project() {
    header "Crear proyecto de Unreal Engine"

    local root="${SCRIPT_DIR}"

    if [[ -n "$ENGINE_BINARY" ]]; then
        info "Abriendo Unreal Editor..."
        info "Crea un nuevo proyecto DENTRO de esta carpeta:"
        echo -e "  ${BOLD}${root}${NC}"
        echo ""
        "$ENGINE_BINARY" &
        info "Unreal Editor se esta abriendo. Crea tu proyecto y cierra el editor cuando termines."
    else
        warn "No se detecto un binario de Unreal Editor."
        echo ""
        echo -e "  ${BOLD}Instrucciones manuales:${NC}"
        echo -e "  1. Abre el ${BOLD}Epic Games Launcher${NC}"
        echo -e "  2. Selecciona ${BOLD}Unreal Engine -> Crear Proyecto${NC}"
        echo -e "  3. Crea el proyecto DENTRO de: ${BOLD}${root}${NC}"
        echo -e "  4. Cierra el editor cuando termines"
    fi

    echo ""
    read -rp "$(echo -e "${CYAN}?${NC}") Presiona ENTER cuando hayas creado el proyecto..."

    # Buscar .uproject en el directorio de trabajo
    cd "$root"
    local uproject_file
    uproject_file=$(find "$root" -maxdepth 2 -name "*.uproject" -print -quit 2>/dev/null || true)

    if [[ -n "$uproject_file" ]]; then
        local ue_dir
        ue_dir=$(dirname "$uproject_file")
        UE_PROJECT_NAME=$(basename "$ue_dir")
        ok "Proyecto detectado: $(basename "$uproject_file") en ${UE_PROJECT_NAME}/"

        # Crear .gitignore del proyecto UE
        info "Creando ${UE_PROJECT_NAME}/.gitignore..."
        cat > "${ue_dir}/.gitignore" << 'GITIGNORE_UE'
# Carpetas de VS y herramientas de desarrollo
.vs/
.vscode/
.idea/

# Compiled Object files
*.slo
*.lo
*.o
*.obj

# Precompiled Headers
*.gch
*.pch

# Compiled Dynamic libraries
*.so
*.dylib
*.dll

# Fortran module files
*.mod

# Compiled Static libraries
*.lai
*.la
*.a
*.lib

# Executables
*.exe
*.out
*.app
*.ipa

# These project files can be generated by the engine
*.xcodeproj
*.xcworkspace
*.sln
*.suo
*.opensdf
*.sdf
*.VC.db
*.VC.opendb
.vsconfig

# Precompiled Assets
SourceArt/**/*.png
SourceArt/**/*.tga

# Binary Files
Binaries/*
Plugins/**/Binaries/*

# Builds
Build/*

# Whitelist PakBlacklist-<BuildConfiguration>.txt files
!Build/*/
Build/*/**
!Build/*/PakBlacklist*.txt

# Don't ignore icon files in Build
!Build/**/*.ico

# Built data for maps
*_BuiltData.uasset

# Configuration files generated by the Editor
Saved/*

# Compiled source files for the engine to use
Intermediate/*
Plugins/**/Intermediate/*

# Cache files for the editor to use
DerivedDataCache/*
GITIGNORE_UE
        ok "${UE_PROJECT_NAME}/.gitignore creado"

        # Actualizar README con el nombre del proyecto
        if [[ -f README.md ]]; then
            echo "- **${UE_PROJECT_NAME}/** - Proyecto de Unreal Engine" >> README.md
        fi

        # Commit del proyecto UE
        info "Creando commit del proyecto UE..."
        git add "${UE_PROJECT_NAME}/" README.md
        git commit -m "feat: Initialize Unreal Engine 5 project (${UE_PROJECT_NAME})"
        ok "Commit del proyecto UE creado"
    else
        warn "No se detecto un archivo .uproject en ${root}"
        if ask_yn "Continuar de todas formas?" "n"; then
            warn "Continuando sin proyecto UE. Puedes agregarlo manualmente despues."
        else
            error "Abortado. Crea el proyecto y ejecuta manualmente:"
            echo -e "  cd ${root}"
            echo -e "  git add <carpeta_proyecto_ue>/"
            echo -e "  git commit -m \"feat: Initialize Unreal Engine 5 project\""
            exit 0
        fi
    fi
}

# ══════════════════════════════════════════════════════════════
# Post-setup
# ══════════════════════════════════════════════════════════════
phase6_postsetup() {
    header "Post-setup"

    local root="${SCRIPT_DIR}"
    cd "$root"

    info "Verificando Git LFS..."
    git lfs ls-files 2>/dev/null || warn "No hay archivos LFS aun (normal para un proyecto nuevo)"

    header "SETUP COMPLETADO"
    echo -e "  ${GREEN}Repositorio:${NC} ${root}"
    echo -e "  ${GREEN}Commits:${NC}"
    git log --oneline
    echo ""

    if [[ -n "$REMOTE_URL" ]]; then
        echo ""
        warn "El segundo commit (proyecto UE) se quedo en LOCAL y no se ha subido al remoto."
        echo -e "  Antes de hacer push puedes editar la plantilla del repositorio."
        echo -e "  Si necesitas modificar el ultimo commit, puedes usar:"
        echo -e "    ${CYAN}git reset --soft HEAD~1${NC}   # Deshace el commit, mantiene los cambios staged"
        echo -e "    ${CYAN}# ... edita lo que necesites ...${NC}"
        echo -e "    ${CYAN}git commit -m \"tu mensaje\"${NC}"
        echo -e "  Cuando estes listo, sube con:"
        echo -e "    ${CYAN}git push${NC}"
        echo ""
    fi

    echo -e "  ${YELLOW}Nota:${NC} Los archivos ${BOLD}.gitkeep${NC} sirven para que Git rastree carpetas vacias."
    echo -e "  Puedes eliminarlos cuando agregues archivos a esa carpeta, o borrarlos si no necesitas la carpeta."
    echo ""
    ok "Tu repositorio esta listo para trabajar."
}

# ══════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════
main() {
    echo -e "${BOLD}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║  Repo2GameEngines - UE5 Repository Initializer  ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    phase1_prerequisites
    phase2_engine
    phase3_params
    phase4_execute
    phase5_ue_project
    phase6_postsetup
}

main "$@"
