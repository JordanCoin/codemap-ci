package main

// Greet is the demo's shared surface. Its signature is the thing two open PRs
// disagree about: one changes it, the other adds a caller using the old one.
func Greet(name string) string {
	return "Hello, " + name + "!"
}
