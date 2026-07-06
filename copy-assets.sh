if [ -f "./envvars.sh" ]; then
	source "./envvars.sh"
fi

ASSETS_INPUT="${ASSETS_INPUT:-$PWD/assets}"
ASSETS_OUTPUT="${ASSETS_OUTPUT:-$PWD/android/app/src/main}"

cp -rv "$ASSETS_INPUT" "$ASSETS_OUTPUT"