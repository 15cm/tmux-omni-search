{ lib
, stdenvNoCC
, makeWrapper
, bash
, tmux
, fzf
}:

stdenvNoCC.mkDerivation {
  pname = "tmux-omni-search";
  version = "0.1.0";

  src = lib.cleanSource ../..;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    plugin_dir="$out/share/tmux-plugins/tmux-omni-search"
    mkdir -p "$plugin_dir/bin"

    cp README.md "$plugin_dir/README.md"
    cp bin/pane-full-text.sh "$plugin_dir/bin/pane-full-text.sh"
    cp tmux-omni-search.tmux "$plugin_dir/tmux-omni-search.tmux"
    chmod +x "$plugin_dir/bin/pane-full-text.sh" "$plugin_dir/tmux-omni-search.tmux"

    wrapProgram "$plugin_dir/bin/pane-full-text.sh" \
      --prefix PATH : "${lib.makeBinPath [ bash tmux fzf ]}"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Popup-based tmux pane full-text search plugin";
    homepage = "https://github.com/sinkerine/tmux-omni-search";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
