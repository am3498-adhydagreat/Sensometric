(function(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.SensometrixCore = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function() {
  'use strict';

  const numericValue = value => (typeof value === 'number' || (typeof value === 'string' && value.trim() !== '')) && Number.isFinite(Number(value)) ? Number(value) : null;
  const finiteNumbers = values => values.map(numericValue).filter(value => value !== null);
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const round = (value, digits = 4) => Number.isFinite(value) ? Number(value.toFixed(digits)) : value;

  function requiredSteps(study, sampleCount) {
    const replications = clamp(Math.trunc(Number(study?.replication_count) || 1), 1, 5);
    const stepsPerReplication = study?.method === 'TRIANGLE' ? 1 : Math.max(1, Number(sampleCount) || 1);
    return replications * stepsPerReplication;
  }

  function progressMeta(session, study, sampleCount) {
    const replications = clamp(Math.trunc(Number(study?.replication_count) || 1), 1, 5);
    const stepsPerReplication = study?.method === 'TRIANGLE' ? 1 : Math.max(1, Number(sampleCount) || 1);
    const totalSteps = requiredSteps(study, sampleCount);
    const completedSteps = clamp(Math.trunc(Number(session?.progress) || 0), 0, totalSteps);
    const activeIndex = Math.min(completedSteps, totalSteps - 1);
    return {
      completedSteps,
      totalSteps,
      percent: Math.round((completedSteps / totalSteps) * 100),
      replicateNumber: Math.min(replications, Math.floor(activeIndex / stepsPerReplication) + 1),
      samplePosition: (activeIndex % stepsPerReplication) + 1,
      complete: completedSteps >= totalSteps && Boolean(session?.completed_at)
    };
  }

  function completeSessionIds(sessions, study, sampleCount) {
    return new Set((sessions || [])
      .filter(session => progressMeta(session, study, sampleCount).complete)
      .map(session => session.id));
  }

  function filterCompleteResponses(responses, sessions, study, sampleCount) {
    const ids = completeSessionIds(sessions, study, sampleCount);
    return (responses || []).filter(response => ids.has(response.session_id));
  }

  function describe(values) {
    const numbers = finiteNumbers(values || []);
    if (!numbers.length) return {n: 0, mean: null, sd: null, min: null, max: null};
    const mean = numbers.reduce((sum, value) => sum + value, 0) / numbers.length;
    const variance = numbers.length > 1
      ? numbers.reduce((sum, value) => sum + ((value - mean) ** 2), 0) / (numbers.length - 1)
      : null;
    return {
      n: numbers.length,
      mean: round(mean),
      sd: variance === null ? null : round(Math.sqrt(variance)),
      min: Math.min(...numbers),
      max: Math.max(...numbers)
    };
  }

  function groupNumericResponses(responses) {
    const buckets = {};
    for (const response of responses || []) {
      const value = numericValue(response.value_num);
      if (!Number.isFinite(value) || !response.sample_id || !response.attribute_id) continue;
      const sample = buckets[response.sample_id] ||= {};
      const attribute = sample[response.attribute_id] ||= {allValues: [], replicateValues: {}};
      attribute.allValues.push(value);
      const replicate = String(Number(response.replicate_number) || 1);
      (attribute.replicateValues[replicate] ||= []).push(value);
    }
    const result = {};
    for (const [sampleId, attributes] of Object.entries(buckets)) {
      result[sampleId] = {};
      for (const [attributeId, bucket] of Object.entries(attributes)) {
        result[sampleId][attributeId] = {
          all: describe(bucket.allValues),
          replicates: Object.fromEntries(Object.entries(bucket.replicateValues).map(([key, values]) => [key, describe(values)]))
        };
      }
    }
    return result;
  }

  function logGamma(value) {
    const coefficients = [676.5203681218851,-1259.1392167224028,771.3234287776531,-176.6150291621406,12.507343278686905,-0.13857109526572012,9.984369578019571e-6,1.5056327351493116e-7];
    if (value < 0.5) return Math.log(Math.PI) - Math.log(Math.sin(Math.PI * value)) - logGamma(1 - value);
    let x = 0.9999999999998099;
    let z = value - 1;
    coefficients.forEach((coefficient, index) => { x += coefficient / (z + index + 1); });
    const t = z + coefficients.length - 0.5;
    return 0.5 * Math.log(2 * Math.PI) + (z + 0.5) * Math.log(t) - t + Math.log(x);
  }

  function betaFraction(a, b, x) {
    const maxIterations = 200;
    const epsilon = 3e-12;
    const tiny = 1e-30;
    const qab = a + b, qap = a + 1, qam = a - 1;
    let c = 1, d = 1 - (qab * x / qap);
    if (Math.abs(d) < tiny) d = tiny;
    d = 1 / d;
    let h = d;
    for (let m = 1; m <= maxIterations; m += 1) {
      const m2 = 2 * m;
      let aa = m * (b - m) * x / ((qam + m2) * (a + m2));
      d = 1 + aa * d;
      if (Math.abs(d) < tiny) d = tiny;
      c = 1 + aa / c;
      if (Math.abs(c) < tiny) c = tiny;
      d = 1 / d;
      h *= d * c;
      aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
      d = 1 + aa * d;
      if (Math.abs(d) < tiny) d = tiny;
      c = 1 + aa / c;
      if (Math.abs(c) < tiny) c = tiny;
      d = 1 / d;
      const delta = d * c;
      h *= delta;
      if (Math.abs(delta - 1) < epsilon) break;
    }
    return h;
  }

  function regularizedBeta(x, a, b) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    const front = Math.exp(logGamma(a + b) - logGamma(a) - logGamma(b) + a * Math.log(x) + b * Math.log(1 - x));
    return x < (a + 1) / (a + b + 2)
      ? front * betaFraction(a, b, x) / a
      : 1 - (front * betaFraction(b, a, 1 - x) / b);
  }

  function oneWayAnova(groups) {
    const clean = (groups || []).map(finiteNumbers).filter(group => group.length);
    const totalN = clean.reduce((sum, group) => sum + group.length, 0);
    if (clean.length < 2 || totalN <= clean.length) return {f: null, p: null, dfBetween: clean.length - 1, dfWithin: totalN - clean.length};
    const all = clean.flat();
    const grandMean = all.reduce((sum, value) => sum + value, 0) / totalN;
    const means = clean.map(group => group.reduce((sum, value) => sum + value, 0) / group.length);
    const ssBetween = clean.reduce((sum, group, index) => sum + group.length * ((means[index] - grandMean) ** 2), 0);
    const ssWithin = clean.reduce((sum, group, index) => sum + group.reduce((inner, value) => inner + ((value - means[index]) ** 2), 0), 0);
    const dfBetween = clean.length - 1, dfWithin = totalN - clean.length;
    if (ssBetween === 0) return {f: 0, p: 1, dfBetween, dfWithin};
    if (ssWithin === 0) return {f: Infinity, p: 0, dfBetween, dfWithin};
    const f = (ssBetween / dfBetween) / (ssWithin / dfWithin);
    const x = dfWithin / (dfWithin + dfBetween * f);
    return {f: round(f), p: round(regularizedBeta(x, dfWithin / 2, dfBetween / 2), 6), dfBetween, dfWithin};
  }

  const responseKey = response => `${response.session_id}|${response.sample_id}|${Number(response.replicate_number) || 1}`;

  function jarPenalty(jarResponses, likingResponses) {
    const jar = (jarResponses || []).filter(response => numericValue(response.value_num) !== null);
    const likingMap = new Map((likingResponses || []).map(response => [responseKey(response), numericValue(response.value_num)]));
    const low = jar.filter(response => Number(response.value_num) < 3);
    const right = jar.filter(response => Number(response.value_num) === 3);
    const high = jar.filter(response => Number(response.value_num) > 3);
    const percent = values => jar.length ? Math.round((values.length / jar.length) * 100) : 0;
    const matchedLiking = group => group.map(response => likingMap.get(responseKey(response))).filter(Number.isFinite);
    const jarMean = describe(matchedLiking(right)).mean;
    const lowMean = describe(matchedLiking(low)).mean;
    const highMean = describe(matchedLiking(high)).mean;
    return {
      distribution: {low: percent(low), jar: percent(right), high: percent(high)},
      penaltyLow: jarMean === null || lowMean === null ? null : round(jarMean - lowMean),
      penaltyHigh: jarMean === null || highMean === null ? null : round(jarMean - highMean),
      matched: {low: matchedLiking(low).length, jar: matchedLiking(right).length, high: matchedLiking(high).length}
    };
  }

  function sensoryMatrix(responses, samples, attributes, replicate = 'all') {
    const filtered = (responses || []).filter(response => {
      if (replicate === 'all') return true;
      return Number(response.replicate_number) === Number(replicate);
    });
    const buckets = new Map();
    for (const response of filtered) {
      const value = numericValue(response.value_num);
      if (!Number.isFinite(value)) continue;
      const key = `${response.sample_id}|${response.attribute_id}`;
      const values = buckets.get(key) || [];
      buckets.set(key, [...values, value]);
    }
    const values = (samples || []).map(sample => (attributes || []).map(attribute => {
      const bucket = buckets.get(`${sample.id}|${attribute.id}`) || [];
      return bucket.length ? bucket.reduce((sum, value) => sum + value, 0) / bucket.length : null;
    }));
    return {
      sampleIds: (samples || []).map(sample => sample.id),
      attributeIds: (attributes || []).map(attribute => attribute.id),
      values,
      responseCount: filtered.filter(response => numericValue(response.value_num) !== null).length,
      replicate
    };
  }

  function jacobiEigen(matrix) {
    const size = matrix.length;
    const values = matrix.map(row => [...row]);
    const vectors = Array.from({length: size}, (_, row) => Array.from({length: size}, (_, column) => row === column ? 1 : 0));
    const maxIterations = Math.max(50, size * size * 100);
    const matrixScale = Math.max(...values.flat().map(Math.abs));
    const tolerance = Number.EPSILON * size * matrixScale;
    for (let iteration = 0; iteration < maxIterations; iteration += 1) {
      let p = 0, q = 1, largest = 0;
      for (let row = 0; row < size; row += 1) {
        for (let column = row + 1; column < size; column += 1) {
          const magnitude = Math.abs(values[row][column]);
          if (magnitude > largest) [largest, p, q] = [magnitude, row, column];
        }
      }
      if (largest <= tolerance) break;
      const angle = 0.5 * Math.atan2(2 * values[p][q], values[q][q] - values[p][p]);
      const cosine = Math.cos(angle), sine = Math.sin(angle);
      const pp = values[p][p], qq = values[q][q], pq = values[p][q];
      for (let index = 0; index < size; index += 1) {
        if (index === p || index === q) continue;
        const ip = values[index][p], iq = values[index][q];
        values[index][p] = values[p][index] = cosine * ip - sine * iq;
        values[index][q] = values[q][index] = sine * ip + cosine * iq;
      }
      values[p][p] = cosine * cosine * pp - 2 * sine * cosine * pq + sine * sine * qq;
      values[q][q] = sine * sine * pp + 2 * sine * cosine * pq + cosine * cosine * qq;
      values[p][q] = values[q][p] = 0;
      for (let row = 0; row < size; row += 1) {
        const vp = vectors[row][p], vq = vectors[row][q];
        vectors[row][p] = cosine * vp - sine * vq;
        vectors[row][q] = sine * vp + cosine * vq;
      }
    }
    return Array.from({length: size}, (_, index) => ({
      value: Math.max(0, values[index][index]),
      vector: vectors.map(row => row[index])
    })).sort((left, right) => right.value - left.value);
  }

  function pca(matrix, mode = 'correlation') {
    if (!['correlation', 'covariance'].includes(mode)) throw new Error('PCA mode must be correlation or covariance');
    if (!Array.isArray(matrix) || matrix.length < 2 || !Array.isArray(matrix[0]) || matrix[0].length < 2) throw new Error('PCA requires at least two products and two attributes');
    const columnCount = matrix[0].length;
    if (matrix.some(row => !Array.isArray(row) || row.length !== columnCount || row.some(value => typeof value !== 'number' || !Number.isFinite(value)))) throw new Error('PCA requires a complete numeric matrix');
    const means = Array.from({length: columnCount}, (_, column) => matrix.reduce((sum, row) => sum + row[column], 0) / matrix.length);
    const variances = means.map((mean, column) => matrix.reduce((sum, row) => sum + ((row[column] - mean) ** 2), 0) / (matrix.length - 1));
    const includedColumnIndices = variances.map((variance, index) => variance > 0 ? index : null).filter(index => index !== null);
    const excludedColumnIndices = variances.map((variance, index) => variance <= 0 ? index : null).filter(index => index !== null);
    if (includedColumnIndices.length < 2) throw new Error('PCA requires at least two varying attributes');
    const transformed = matrix.map(row => includedColumnIndices.map(column => {
      const centered = row[column] - means[column];
      return mode === 'correlation' ? centered / Math.sqrt(variances[column]) : centered;
    }));
    const covariance = includedColumnIndices.map((_, left) => includedColumnIndices.map((__, right) => transformed.reduce((sum, row) => sum + row[left] * row[right], 0) / (matrix.length - 1)));
    const eigen = jacobiEigen(covariance);
    // Keep computational values unrounded; format only at the presentation boundary.
    const eigenvalues = eigen.map(item => item.value);
    const totalVariance = eigenvalues.reduce((sum, value) => sum + value, 0);
    const explainedVariance = eigenvalues.map(value => round(totalVariance ? value / totalVariance * 100 : 0, 6));
    const scores = transformed.map(row => eigen.map(item => row.reduce((sum, value, index) => sum + value * item.vector[index], 0)));
    const loadings = includedColumnIndices.map((_, row) => eigen.map(item => item.vector[row] * Math.sqrt(item.value)));
    return {mode, eigenvalues, explainedVariance, scores, loadings, includedColumnIndices, excludedColumnIndices, means: includedColumnIndices.map(index => means[index]), scales: includedColumnIndices.map(index => mode === 'correlation' ? Math.sqrt(variances[index]) : 1)};
  }

  function triangleExact(total, correct) {
    const n = Number(total), k = Number(correct);
    if (!Number.isSafeInteger(n) || !Number.isSafeInteger(k) || n < 0 || k < 0 || k > n) throw new Error('Triangle counts must be integers with 0 <= correct <= total');
    if (!n) return {total: 0, correct: 0, pValue: null, significant: false};
    const pValue = k === 0 ? 1 : clamp(regularizedBeta(1 / 3, k, n - k + 1), 0, 1);
    return {total:n, correct:k, pValue, significant:pValue < 0.05};
  }

  // Blocked/repeated observations require a design-specific model. Never silently
  // feed them into the independent-groups ANOVA retained for external callers.
  function designAnova() {
    return {f:null,p:null,dfBetween:'—',dfWithin:'—',reason:'Repeated panelist design: inferential model not yet enabled'};
  }

  return {
    numericValue,
    designAnova,
    requiredSteps,
    progressMeta,
    completeSessionIds,
    filterCompleteResponses,
    describe,
    groupNumericResponses,
    oneWayAnova,
    jarPenalty,
    sensoryMatrix,
    pca,
    triangleExact
  };
});
