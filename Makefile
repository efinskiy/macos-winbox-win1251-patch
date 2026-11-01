PYTHON ?= python3

.PHONY: build decoder test verify clean

decoder:
	$(PYTHON) build.py

build: decoder
	$(PYTHON) SwiftPatcher/build.py

test: decoder
	$(PYTHON) tests/test_codec.py
	$(PYTHON) tests/test_bridge.py

verify:
	$(PYTHON) scripts/verify_package.py

clean:
	$(PYTHON) -c 'import shutil; [shutil.rmtree(p, ignore_errors=True) for p in ("build", "SwiftPatcher/build", "SwiftPatcher/dist")]'
