import { render, screen } from '@testing-library/react';
import Home from './Home';

describe('Home', () => {
  it('shows the name and tagline', () => {
    render(<Home />);
    expect(screen.getByRole('heading', { name: 'Big Bucks' })).toBeInTheDocument();
    expect(screen.getByText('Watch your bucks grow.')).toBeInTheDocument();
  });
});
