.PHONY: all clean verify jasm class run

CC=cc
LEX=lex
YACC=yacc
PARSER=./parser
JAVAA=javaa
JAVA=java

SRCS=src/ast.c

TEST_DIR=testcase
# TEST=trivial
# TEST=HelloWorld
# TEST=example
# TEST=fib
# TEST=sigma
TEST=tricky
# TEST=Primes
# TEST=Classics
# TEST=NumberTheory
TESTCASE=$(TEST_DIR)/$(TEST).del
JASM=$(TEST_DIR)/$(TEST).jasm
CLASS=$(TEST_DIR)/$(TEST).class

ALL_TESTS=$(wildcard $(TEST_DIR)/*.del)
ERR_TESTS=$(wildcard $(TEST_DIR)/err_*.del)
PASS_TESTS=$(filter-out $(ERR_TESTS), $(ALL_TESTS))

all: $(PARSER)

run: $(CLASS)
	$(JAVA) -cp $(<D) $(notdir $(basename $<))

class: $(CLASS)

jasm: $(JASM)

%.class: %.jasm
	cd $(@D); $(JAVAA) $(notdir $<)

%.jasm: %.del $(PARSER)
	$(PARSER) < $< | tee $@

$(PARSER): src/lex.yy.c src/y.tab.c $(SRCS)
	$(CC) $^ -o $(PARSER)

src/lex.yy.c: src/lex.l
	$(LEX) -o src/lex.yy.c $<

src/y.tab.c src/y.tab.h: src/yacc.y
	$(YACC) -o src/y.tab.c -d $<

clean:
	rm -f src/lex.yy.c src/y.tab.c src/y.tab.h $(PARSER) testcase/*.jasm testcase/*.class

# 自動化驗證腳本
verify: $(PARSER)
	@echo "\n========== [ Verify Correct Testcases ] =========="
	@for file in $(PASS_TESTS); do \
		./$(PARSER) < "$$file" > .tmp.log 2>&1; \
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
		./$(PARSER) < "$$file" > .tmp.log 2>&1; \
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