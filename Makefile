.PHONY: all cli app install run test clean

all: cli app

cli:  ## install the scoreboard CLI onto PATH (editable)
	cd cli && uv tool install --force --editable .

app:  ## build Scoreboard.app
	$(MAKE) -C app app

install: cli app  ## install CLI + copy app to ~/Applications
	rm -rf ~/Applications/Scoreboard.app
	mkdir -p ~/Applications
	cp -R app/build/Scoreboard.app ~/Applications/

run: app  ## build and (re)launch the menu bar app
	@# `open` only activates an already-running app; kill first so the new build runs
	-pkill -x Scoreboard
	open app/build/Scoreboard.app

test:
	cd cli && uv run python -m unittest discover -s tests

clean:
	$(MAKE) -C app clean
