-module(proc_test).
-export([loop/0]).

loop() ->
  receive
    bye -> io:format("bye!");
    _ -> loop()
  end.
