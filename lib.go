package main

import "strings"

// Greet is the demo's shared surface. Its signature is the thing two open PRs
// disagree about: one changes it, the other adds a caller using the old one.
func Greet(name string, loud bool) string {
	greeting := "Hello, " + name + "!"
	if loud {
		return strings.ToUpper(greeting)
	}
	return greeting
}
