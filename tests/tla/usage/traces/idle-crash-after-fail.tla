---------------- MODULE idle_crash_after_fail ----------------
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
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_2 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 0
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> None @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_3 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 1
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 1
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> None @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
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
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 1
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 1 @@ p2 :> None)
/\ failedAt = (p1 :> None @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> a, fin |-> TRUE, at |-> 1] @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
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
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 1
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 1 @@ p2 :> None)
/\ failedAt = (p1 :> 1 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
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
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 2
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 1 @@ p2 :> None)
/\ failedAt = (p1 :> 1 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
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
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 1 @@ p2 :> None)
/\ failedAt = (p1 :> 1 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_8 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 2
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 1 @@ p2 :> None)
/\ failedAt = (p1 :> 1 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_9 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 2
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 2 @@ p2 :> None)
/\ failedAt = (p1 :> 1 @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> a, fin |-> TRUE, at |-> 2] @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_10 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 2
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 2 @@ p2 :> None)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_11 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 3
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 2 @@ p2 :> None)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_12 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 2 @@ p2 :> None)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_13 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 2 @@ p2 :> 4)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> [ident |-> a, fin |-> TRUE, at |-> 4])
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_14 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 4 @@ p2 :> 4)
/\ failedAt = (p1 :> 2 @@ p2 :> None)
/\ inflight = ( p1 :> [ident |-> a, fin |-> TRUE, at |-> 4] @@
  p2 :> [ident |-> a, fin |-> TRUE, at |-> 4] )
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_15 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 4 @@ p2 :> 4)
/\ failedAt = (p1 :> 2 @@ p2 :> 4)
/\ inflight = (p1 :> [ident |-> a, fin |-> TRUE, at |-> 4] @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_16 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 4
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 4 @@ p2 :> 4)
/\ failedAt = (p1 :> 4 @@ p2 :> 4)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_17 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 5
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 4 @@ p2 :> 4)
/\ failedAt = (p1 :> 4 @@ p2 :> 4)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_18 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 5
/\ shown = ( p1 :> [ident |-> a, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 4 @@ p2 :> 5)
/\ failedAt = (p1 :> 4 @@ p2 :> 4)
/\ inflight = (p1 :> None @@ p2 :> [ident |-> a, fin |-> TRUE, at |-> 5])
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_19 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 5
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 4 @@ p2 :> 5)
/\ failedAt = (p1 :> 4 @@ p2 :> 4)
/\ inflight = (p1 :> None @@ p2 :> [ident |-> a, fin |-> TRUE, at |-> 5])
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )
/\ cache = ( a :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_20 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 5
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> 5, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 4 @@ p2 :> 5)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> None, todayAt |-> None, finDay |-> None] @@
  p2 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_21 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 5
/\ shown = ( p1 :> [ident |-> a, today |-> 5, fin |-> 1] @@
  p2 :> [ident |-> a, today |-> 5, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 5 @@ p2 :> 5)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> a, fin |-> FALSE, at |-> 5] @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_22 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 5
/\ shown = ( p1 :> [ident |-> a, today |-> 5, fin |-> 1] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 5 @@ p2 :> 5)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> a, fin |-> FALSE, at |-> 5] @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_23 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> a, today |-> 5, fin |-> 1] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 5 @@ p2 :> 5)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> a, fin |-> FALSE, at |-> 5] @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_24 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 5 @@ p2 :> 5)
/\ failedAt = (p1 :> 4 @@ p2 :> None)
/\ inflight = (p1 :> [ident |-> a, fin |-> FALSE, at |-> 5] @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_25 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 5 @@ p2 :> 5)
/\ failedAt = (p1 :> 6 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_26 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> 5, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 5 @@ p2 :> 6)
/\ failedAt = (p1 :> 6 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> [ident |-> a, fin |-> FALSE, at |-> 6])
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_27 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> None, today |-> None, fin |-> None] @@
  p2 :> [ident |-> a, today |-> 6, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> FALSE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 5 @@ p2 :> 6)
/\ failedAt = (p1 :> 6 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 5, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_28 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> a, today |-> 6, fin |-> 1] @@
  p2 :> [ident |-> a, today |-> 6, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 5 @@ p2 :> 6)
/\ failedAt = (p1 :> 6 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_29 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> a, today |-> 6, fin |-> 1] @@
  p2 :> [ident |-> None, today |-> None, fin |-> None] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> FALSE)
/\ lastStart = (p1 :> 5 @@ p2 :> 6)
/\ failedAt = (p1 :> 6 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


STATE_30 == 
/\ corrupt = (a :> FALSE @@ b :> FALSE)
/\ skew = 0
/\ now = 6
/\ shown = ( p1 :> [ident |-> a, today |-> 6, fin |-> 1] @@
  p2 :> [ident |-> a, today |-> 6, fin |-> 1] )
/\ corruptions = (a :> 0 @@ b :> 0)
/\ faults = 3
/\ open = (p1 :> TRUE @@ p2 :> TRUE)
/\ lastStart = (p1 :> 5 @@ p2 :> 6)
/\ failedAt = (p1 :> 6 @@ p2 :> None)
/\ inflight = (p1 :> None @@ p2 :> None)
/\ ident = (p1 :> a @@ p2 :> a)
/\ finCount = ( p1 :> (a :> (0 :> 0 @@ 1 :> 0) @@ b :> (0 :> 0 @@ 1 :> 0)) @@
  p2 :> (a :> (0 :> 0 @@ 1 :> 1) @@ b :> (0 :> 0 @@ 1 :> 0)) )
/\ mem = ( p1 :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] @@
  p2 :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] )
/\ cache = ( a :> [todayDay |-> 1, todayAt |-> 6, finDay |-> 1] @@
  b :> [todayDay |-> None, todayAt |-> None, finDay |-> None] )


=================================================
