package main

// greetAgain is a new caller added while PR A is still open. It uses the
// Greet signature that exists on main today.
func greetAgain() string {
	return Greet("x")
}
