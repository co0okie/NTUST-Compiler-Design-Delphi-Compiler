# TESTCASE=testcase/commentcommentcomment.del
TESTCASE=testcase/example.del
# TESTCASE=testcase/fib.del
# TESTCASE=testcase/HelloWorld.del
# TESTCASE=testcase/longlongstring.del
# TESTCASE=testcase/sigma.del

all: lex

lex.yy.c: lex.l
	lex $^

lex: lex.yy.c
	cc $^ -ll -o $@

run: lex $(TESTCASE)
	./lex < $(TESTCASE)

clean:
	rm lex lex.yy.c
