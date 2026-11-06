APP_NAME    := Zyo
APP         := build/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Library/Input Methods
RIME_USER   := $(HOME)/Library/Application Support/Zyo/rime
# CLT 27.0（2026-10）的 SDK 把 SwiftUI @State 改成宏，却没带 SwiftUIMacros 插件，编译失败；暂用 26.5 SDK（CLT 27.2 仍未修复，2026-11-05 验证）
SDK_26_5    := /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
ifneq ($(wildcard $(SDK_26_5)),)
export SDKROOT ?= $(SDK_26_5)
endif
# 用 = 延迟求值，只有 make install 才调用 brew
RIME_DEPLOY  = $(shell brew --prefix librime)/bin/rime_deployer
# 雾凇拼音固定版本，升级时改这里后执行 make clean-vendor build
RIME_ICE_REV := da1fbe602e38f26db846fa10120ee64c2b0324c0
# 上面提交的时间，写进 Info.plist，在线更新词典时用来判断是否有新版本
RIME_ICE_DATE := 2026-10-05T13:37:01Z
RIME_ICE     := vendor/rime-ice
# 极点五笔 86（Apache-2.0）固定版本，升级方式同上
WUBI_REV     := 18a6016c3d08a20f713f8f8e1791a2e79e0be081
WUBI         := vendor/rime-wubi86
WUBI_FILES   := wubi86_jidian.schema.yaml wubi86_jidian.dict.yaml wubi86_jidian_extra.dict.yaml \
                wubi86_jidian_user.dict.yaml wubi86_jidian_user_hamster.dict.yaml pinyin_simp.dict.yaml pinyin_simp.schema.yaml
# 五笔 98（lotem/rime-wubi98，词典标注 GPLv3）
WUBI98_REV   := 0bc5b2b296f536d38ffe38381d37e5011da55e59
WUBI98       := vendor/rime-wubi98
# 新世纪五笔（byujiang/wubi06_rime，GPL-3.0）：只取词典，方案用 Resources/rime/wubi06.schema.yaml
WUBI06_REV   := fc1cedbb21cde3ca160ce291888fa70697720ab3
WUBI06       := vendor/rime-wubi06
# librime 官方发布版（依赖已静态链接，最低 macOS 10.15），只给 make dist 用；Homebrew 版只支持打包机的系统版本
LIBRIME_URL := https://github.com/rime/librime/releases/download/1.17.0/rime-33e7814-macOS-universal.tar.bz2
LIBRIME_SHA := 11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850
LIBRIME     := vendor/librime-macos
CLT_DEV     := /Library/Developer/CommandLineTools/Library/Developer
# 只装了 Command Line Tools 时，Swift Testing 不在默认搜索路径
TEST_FLAGS  := -Xswiftc -F$(CLT_DEV)/Frameworks -Xlinker -F$(CLT_DEV)/Frameworks \
               -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib \
               -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

VERSION     := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
DIST        := build/dist/$(APP_NAME)

.PHONY: build install dist uninstall log test clean clean-vendor

$(RIME_ICE):
	mkdir -p vendor
	curl -sfL https://codeload.github.com/iDvel/rime-ice/tar.gz/$(RIME_ICE_REV) | tar xz -C vendor
	mv vendor/rime-ice-$(RIME_ICE_REV) $(RIME_ICE)

$(WUBI):
	mkdir -p vendor
	curl -sfL https://codeload.github.com/KyleBing/rime-wubi86-jidian/tar.gz/$(WUBI_REV) | tar xz -C vendor
	mv vendor/rime-wubi86-jidian-$(WUBI_REV) $(WUBI)

$(WUBI98):
	mkdir -p vendor
	curl -sfL https://codeload.github.com/lotem/rime-wubi98/tar.gz/$(WUBI98_REV) | tar xz -C vendor
	mv vendor/rime-wubi98-$(WUBI98_REV) $(WUBI98)

$(WUBI06):
	mkdir -p vendor
	curl -sfL https://codeload.github.com/byujiang/wubi06_rime/tar.gz/$(WUBI06_REV) | tar xz -C vendor
	mv vendor/wubi06_rime-$(WUBI06_REV) $(WUBI06)
	@# 上游 .gitattributes 让 tar 包不含 LICENSE，单独下载
	curl -sfL https://raw.githubusercontent.com/byujiang/wubi06_rime/$(WUBI06_REV)/LICENSE -o $(WUBI06)/LICENSE

$(LIBRIME):
	mkdir -p vendor
	curl -sfL $(LIBRIME_URL) -o $@.tar.bz2
	echo "$(LIBRIME_SHA)  $@.tar.bz2" | shasum -a 256 -c -
	rm -rf $@.tmp && mkdir -p $@.tmp && tar xjf $@.tar.bz2 -C $@.tmp
	mv $@.tmp/dist $@ && rm -rf $@.tmp $@.tar.bz2

build: $(RIME_ICE) $(WUBI) $(WUBI98) $(WUBI06)
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/$(APP_NAME) $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	/usr/libexec/PlistBuddy -c "Add :ZyoDictionaryDate string $(RIME_ICE_DATE)" $(APP)/Contents/Info.plist
	cp Resources/icon.tiff Resources/AppIcon.icns Resources/rime/default.custom.yaml $(APP)/Contents/Resources/
	cp -R Resources/en.lproj Resources/zh-Hans.lproj $(APP)/Contents/Resources/
	rsync -a --exclude others --exclude build --exclude '*.md' --exclude '.*' \
		--exclude squirrel.yaml --exclude weasel.yaml --exclude t9.schema.yaml --exclude recipe.yaml \
		$(RIME_ICE)/ $(APP)/Contents/Resources/rime-data/
	cp $(addprefix $(WUBI)/,$(WUBI_FILES)) $(APP)/Contents/Resources/rime-data/
	cp $(WUBI)/LICENSE $(APP)/Contents/Resources/rime-data/wubi86_jidian.LICENSE
	@# 去掉反查提示「〔拼音〕」，否则会出现在 marked text 里，与五笔 86 保持一致
	sed '/^  tips:/d' $(WUBI98)/wubi98.schema.yaml > $(APP)/Contents/Resources/rime-data/wubi98.schema.yaml
	cp $(WUBI98)/wubi98.dict.yaml $(APP)/Contents/Resources/rime-data/
	cp $(WUBI06)/dicts/wubi06.dict.yaml Resources/rime/wubi06.schema.yaml $(APP)/Contents/Resources/rime-data/
	cp $(WUBI06)/LICENSE $(APP)/Contents/Resources/rime-data/wubi06.LICENSE
	codesign --force --sign - $(APP)

install: build
	-killall $(APP_NAME) 2>/dev/null
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	mkdir -p "$(INSTALL_DIR)"
	cp -R $(APP) "$(INSTALL_DIR)/"
	swift Scripts/register.swift "$(INSTALL_DIR)/$(APP_NAME).app"
	@# 预先编译词库，首次切换到输入法时无需等待部署
	mkdir -p "$(RIME_USER)"
	cp Resources/rime/default.custom.yaml "$(RIME_USER)/"
	$(RIME_DEPLOY) --build "$(RIME_USER)" "$(INSTALL_DIR)/$(APP_NAME).app/Contents/Resources/rime-data" "$(RIME_USER)/build" 2>/dev/null

# 给没装 Homebrew 的同事用：官方 librime 打包进 App，注册工具预编译，解压后 bash install.sh
dist: build $(LIBRIME)
	rm -rf build/dist
	mkdir -p $(DIST)
	cp -R $(APP) $(DIST)/
	Scripts/bundle_dylibs.sh $(DIST)/$(APP_NAME).app $(LIBRIME)/lib
	@# 不指定 target 时最低版本等于本机系统，与 install.sh 检查的 macOS 26 对不上
	swiftc -O -target arm64-apple-macos26.0 Scripts/register.swift -o $(DIST)/register
	cp Scripts/install.sh $(DIST)/
	cd build/dist && ditto -c -k --norsrc --keepParent $(APP_NAME) ../$(APP_NAME)-$(VERSION).zip
	@echo "已生成 build/$(APP_NAME)-$(VERSION).zip"

uninstall:
	-killall $(APP_NAME) 2>/dev/null
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

log:
	log stream --level debug --predicate 'subsystem == "com.owen.inputmethod.Zyo"'

test:
	swift test $(TEST_FLAGS)

clean:
	rm -rf .build build

clean-vendor:
	rm -rf vendor
