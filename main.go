package main

import "fmt"

// The demo: a two-file Go program small enough that a merge-order collision is
// the only interesting thing about it. See README.md.

func main() {
	fmt.Println(Greet("world", true))

	report()
}

// report is deliberately far from the Greet call above, so the two demo PRs
// edit this file without a textual git conflict. Git merges them cleanly; the
// compiler is the one that objects.

func report() {
	fmt.Println(banner())

	fmt.Println(footer())
}

func banner() string {
	return "codemap-ci demo"
}

func footer() string {
	return "---"
}
