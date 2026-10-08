SHELL := /bin/bash
DERIVED_DATA := .build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/FeishuChat.app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/FeishuChat.app
BACKEND_REVISION ?= $(shell git rev-parse HEAD)
XCODEBUILD := xcodebuild -project FeishuChat.xcodeproj -scheme FeishuChat \
	-destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA)

.PHONY: gen build build-release dmg test run dev clean

# 从 project.yml 重新生成 FeishuChat.xcodeproj（xcodeproj 不入库）
gen:
	xcodegen

build: gen
	set -o pipefail && $(XCODEBUILD) -configuration Debug build | xcbeautify

build-release: gen
	set -o pipefail && $(XCODEBUILD) -configuration Release build ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO FEISHU_BACKEND_REVISION=$(BACKEND_REVISION) $(RELEASE_XCARGS) | xcbeautify

dmg:
	bash scripts/make-dmg.sh "$(RELEASE_APP)" dist

# FeishuChatCore 纯逻辑单测
test:
	cd FeishuChatCore && swift test

# kill 后等旧进程退出，再用 open -n 强制新实例启动：
# 普通 open 在进程刚退出时会撞上 LaunchServices 的滞留注册而报 -600。
# 需要给 app 注入环境变量时用 open -n --env KEY=value $(APP)
# （open 启动的 app 不继承 shell 环境）。
run:
	@pkill -x FeishuChat 2>/dev/null || true
	@for i in $$(seq 1 20); do pgrep -qx FeishuChat || break; sleep 0.1; done
	@open -n $(APP)

dev: build run

clean:
	rm -rf $(DERIVED_DATA) FeishuChatCore/.build FeishuChat.xcodeproj
