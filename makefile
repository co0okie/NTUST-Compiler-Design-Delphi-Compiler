.PHONY: all clean verify run

CC=cc
LEX=lex
YACC=yacc
EXE=parser

TEST_DIR=testcase
TEST=example.del
# TEST=fib.del
# TEST=HelloWorld.del
# TEST=sigma.del
# TEST=tricky.del
TESTCASE=$(TEST_DIR)/$(TEST)

# 自動抓取 testcase 目錄下的檔案
ALL_TESTS=$(wildcard $(TEST_DIR)/*.del)
ERR_TESTS=$(wildcard $(TEST_DIR)/err_*.del)
# 使用 filter-out 過濾掉錯誤測資，剩下的就是預期正確的測資
PASS_TESTS=$(filter-out $(ERR_TESTS), $(ALL_TESTS))

all: $(EXE)

run: $(EXE)
	./$(EXE) < $(TESTCASE)

$(EXE): src/lex.yy.c src/y.tab.c
	$(CC) $^ -o $(EXE)

src/lex.yy.c: src/lex.l
	$(LEX) -o src/lex.yy.c $<

src/y.tab.c src/y.tab.h: src/yacc.y
	$(YACC) -o src/y.tab.c -d $<

clean:
	rm -f src/lex.yy.c src/y.tab.c y.tab.h $(EXE)

# 自動化驗證腳本
verify: $(EXE)
	@echo "\n========== [ Verify Correct Testcases ] =========="
	@for file in $(PASS_TESTS); do \
		./$(EXE) < "$$file" > .tmp.log 2>&1; \
		STATUS=$$?; \
		if [ $$STATUS -eq 0 ]; then \
			echo "  [PASS] $$file"; \
		else \
			echo "  [FAIL] $$file (Expected success but failed!)"; \
			echo "--- Output Log ---"; \
			cat .tmp.log; \
			echo "------------------"; \
			rm -f .tmp.log; \
			exit 1; \
		fi; \
	done
	@rm -f .tmp.log
	@echo "\n========== [ Verify Error Testcases ] =========="
	@for file in $(ERR_TESTS); do \
		./$(EXE) < "$$file" > .tmp.log 2>&1; \
		STATUS=$$?; \
		if [ $$STATUS -ne 0 ]; then \
			echo "  [PASS] $$file (Failed as expected)"; \
		else \
			echo "  [FAIL] $$file (Expected failure but succeeded!)"; \
			echo "--- Output Log ---"; \
			cat .tmp.log; \
			echo "------------------"; \
			rm -f .tmp.log; \
			exit 1; \
		fi; \
	done
	@rm -f .tmp.log
	@echo "\n=> All verification passed successfully!"