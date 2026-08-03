.PHONY: all app install run test clean

all: app

app:  ## build Scoreboard.app (menu bar app + embedded CLI)
	$(MAKE) -C app app

install: app  ## install to ~/Applications and put the CLI on PATH
	rm -rf ~/Applications/Scoreboard.app
	mkdir -p ~/Applications ~/.local/bin
	cp -R app/build/Scoreboard.app ~/Applications/
	ln -sf ~/Applications/Scoreboard.app/Contents/Resources/scoreboard ~/.local/bin/scoreboard

run: app  ## build and (re)launch the menu bar app
	@# `open` only activates an already-running app; kill first so the new build runs
	-pkill -x Scoreboard
	open app/build/Scoreboard.app

test:
	cd app && swift test

clean:
	$(MAKE) -C app clean
