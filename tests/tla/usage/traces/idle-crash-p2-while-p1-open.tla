---------------- MODULE idle_crash_p2_while_p1_open ----------------
STATE_1 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 0
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 0
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> None @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_2 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 0
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 0
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_3 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 0
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 1
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_4 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 1
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_5 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 1
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_6 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 2
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_7 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> b, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 2
/\ open = (p1 :> FALSE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 0 @@ p2 :> 1)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = ( p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@
  p2 :> [ident |-> b, fin |-> TRUE, at |-> 1] )
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_8 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 2
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> 1)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = ( p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@
  p2 :> [ident |-> b, fin |-> TRUE, at |-> 1] )
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_9 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> b, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 2
/\ open = (p1 :> FALSE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 0 @@ p2 :> 1)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = ( p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@
  p2 :> [ident |-> b, fin |-> TRUE, at |-> 1] )
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_10 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_11 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 2
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_12 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 2
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 0] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_13 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 2
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_14 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 2
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_15 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 2
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_16 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 3
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 0 @@ p2 :> None)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_17 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 3
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 3 @@ p2 :> None)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 3] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_18 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 3
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 3 @@ p2 :> None)
/\ failedAt = (p1 :> 3 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_19 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 3 @@ p2 :> None)
/\ failedAt = (p1 :> 3 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_20 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 3 @@ p2 :> None)
/\ failedAt = (p1 :> 3 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_21 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 4 @@ p2 :> None)
/\ failedAt = (p1 :> 3 @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 4] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_22 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 4 @@ p2 :> None)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_23 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 5
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 4 @@ p2 :> None)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_24 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 4 @@ p2 :> None)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_25 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 7
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 4 @@ p2 :> None)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_26 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 7
/\ shown = ( p1 :> [ident |-> b, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 7 @@ p2 :> None)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> b, fin |-> TRUE, at |-> 7] @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_27 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 7
/\ shown = ( p1 :> [ident |-> b, today |-> 7, fin |-> 1] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 7 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 1)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] )


STATE_28 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 7
/\ shown = ( p1 :> [ident |-> b, today |-> 7, fin |-> 1] @@
  p2 :> [ident |-> b, today |-> 7, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 7 @@ p2 :> 7)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> [ident |-> b, fin |-> FALSE, at |-> 7])
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 1)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] )


STATE_29 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 7
/\ shown = ( p1 :> [ident |-> b, today |-> 7, fin |-> 1] @@
  p2 :> [ident |-> b, today |-> 7, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 7 @@ p2 :> 7)
/\ failedAt = (p1 :> None @@ p2 :> 7)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 1)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] )


STATE_30 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 7
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> b, today |-> 7, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 7 @@ p2 :> 7)
/\ failedAt = (p1 :> None @@ p2 :> 7)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> b @@ p2 :> b)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 1)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> 1, todayAt |-> 7, finDay |-> 1] )


=================================================
