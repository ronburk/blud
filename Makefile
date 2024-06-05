COLON = :
a $(COLON) b

b : ; echo making b

a :
	echo $(SET)

define ACTION
	echo action!!!
endef
define RULE
x :
$(ACTION)
endef
define RULE2
y :
endef

$(RULE)
$(RULE2)

a :

FOO:=$$
GLOBAL_VAR = $(FOO)x
FEE=$(GLOBAL_VAR)

all: private GLOBAL_VAR = y
all: one
	echo $(FOO)$(FEE)
	echo $(GLOBAL_VAR)

one:
	echo $(GLOBAL_VAR)
